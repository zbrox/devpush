flake:

{ config, lib, pkgs, ... }:

let
  cfg = config.services.devpush;
  inherit (lib) mkEnableOption mkOption mkIf types optionalString;

  # Build the compose command arguments
  composeFiles = [
    "${cfg.package}/compose/base.yml"
    "${cfg.package}/compose/override.yml"
    "${cfg.package}/compose/ssl-${cfg.settings.certChallengeProvider}.yml"
  ];

  composeFileArgs = lib.concatMapStringsSep " " (f: "-f ${f}") composeFiles;

  # Script to generate secrets if they don't exist
  generateSecretsScript = pkgs.writeShellScript "devpush-generate-secrets" ''
    set -euo pipefail

    SECRETS_DIR="${cfg.dataDir}/secrets"
    GENERATED_NEW=false

    # Create secrets directory if it doesn't exist
    if [[ ! -d "$SECRETS_DIR" ]]; then
      mkdir -p "$SECRETS_DIR"
      chmod 700 "$SECRETS_DIR"
      chown ${cfg.user}:${cfg.group} "$SECRETS_DIR"
    fi

    # Generate encryption key if missing
    if [[ ! -f "$SECRETS_DIR/encryption.key" ]]; then
      echo "Generating encryption key..."
      ${pkgs.openssl}/bin/openssl rand -base64 32 | tr '+/' '-_' > "$SECRETS_DIR/encryption.key"
      chmod 600 "$SECRETS_DIR/encryption.key"
      chown ${cfg.user}:${cfg.group} "$SECRETS_DIR/encryption.key"
      GENERATED_NEW=true
    fi

    # Generate session key if missing
    if [[ ! -f "$SECRETS_DIR/session.key" ]]; then
      echo "Generating session key..."
      ${pkgs.openssl}/bin/openssl rand -hex 32 > "$SECRETS_DIR/session.key"
      chmod 600 "$SECRETS_DIR/session.key"
      chown ${cfg.user}:${cfg.group} "$SECRETS_DIR/session.key"
      GENERATED_NEW=true
    fi

    # Generate postgres password if missing
    if [[ ! -f "$SECRETS_DIR/postgres.password" ]]; then
      echo "Generating postgres password..."
      ${pkgs.openssl}/bin/openssl rand -hex 32 > "$SECRETS_DIR/postgres.password"
      chmod 600 "$SECRETS_DIR/postgres.password"
      chown ${cfg.user}:${cfg.group} "$SECRETS_DIR/postgres.password"
      GENERATED_NEW=true
    fi

    # Create README if it doesn't exist
    if [[ ! -f "$SECRETS_DIR/README.txt" ]]; then
      cat > "$SECRETS_DIR/README.txt" <<'EOF'
DevPush Secrets Directory
=========================

This directory contains cryptographic keys and passwords essential to DevPush.
These files are automatically generated on first run if not present.

Files:
  encryption.key   - Used to encrypt sensitive data in the database.
                     If lost, encrypted data becomes unrecoverable.

  session.key      - Used for signing session tokens.
                     If changed, all active sessions will be invalidated.

  postgres.password - Password for the PostgreSQL database.
                     Must match the password used when the database was created.

IMPORTANT: Back up this entire directory!
Without these keys, your data cannot be recovered.
EOF
      chmod 644 "$SECRETS_DIR/README.txt"
      chown ${cfg.user}:${cfg.group} "$SECRETS_DIR/README.txt"
    fi

    # Warn on first generation
    if [[ "$GENERATED_NEW" == "true" ]]; then
      echo ""
      echo "========================================================"
      echo "WARNING: New cryptographic secrets have been generated."
      echo ""
      echo "BACK UP THIS DIRECTORY IMMEDIATELY:"
      echo "  ${cfg.dataDir}/secrets/"
      echo ""
      echo "Without these files, your data cannot be recovered."
      echo "========================================================"
      echo ""
    fi
  '';

  # Script to build the combined .env file
  buildEnvScript = pkgs.writeShellScript "devpush-build-env" ''
    set -euo pipefail

    ENV_FILE="${cfg.dataDir}/.env"
    SECRETS_DIR="${cfg.dataDir}/secrets"
    USER_SECRETS="${cfg.secretsFile}"

    # Helper to read a secret, with optional override from user secrets file
    read_secret() {
      local name="$1"
      local file="$2"
      local value=""

      # Check user secrets file first (takes priority)
      if [[ -f "$USER_SECRETS" ]]; then
        value=$(${pkgs.gnugrep}/bin/grep -E "^$name=" "$USER_SECRETS" 2>/dev/null | head -1 | cut -d= -f2- || true)
      fi

      # Fall back to auto-generated secret
      if [[ -z "$value" && -f "$file" ]]; then
        value=$(cat "$file")
      fi

      # Error if still empty
      if [[ -z "$value" ]]; then
        echo "ERROR: Required secret '$name' not found." >&2
        echo "Expected at: $file" >&2
        echo "Or provide it in: $USER_SECRETS" >&2
        exit 1
      fi

      echo "$value"
    }

    # Read secrets (user-provided values override auto-generated)
    ENCRYPTION_KEY=$(read_secret "ENCRYPTION_KEY" "$SECRETS_DIR/encryption.key")
    SECRET_KEY=$(read_secret "SECRET_KEY" "$SECRETS_DIR/session.key")
    POSTGRES_PASSWORD=$(read_secret "POSTGRES_PASSWORD" "$SECRETS_DIR/postgres.password")

    # Get UID/GID
    SERVICE_UID=$(${pkgs.coreutils}/bin/id -u ${cfg.user})
    SERVICE_GID=$(${pkgs.coreutils}/bin/id -g ${cfg.user})

    # Detect server IP if not specified
    SERVER_IP="${optionalString (cfg.settings.serverIp != null) cfg.settings.serverIp}"
    if [[ -z "$SERVER_IP" ]]; then
      SERVER_IP=$(${pkgs.curl}/bin/curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || \
                  ${pkgs.curl}/bin/curl -fsS --max-time 5 http://checkip.amazonaws.com 2>/dev/null || \
                  ${pkgs.iproute2}/bin/ip route get 1 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $7; exit}' || \
                  echo "127.0.0.1")
    fi

    # Build the .env file
    # Note: DATA_DIR, APP_DIR, LOG_DIR are intentionally NOT included here.
    # These are host paths used by docker-compose for volume mounts (passed via
    # shell environment). The app container uses its defaults (/data, /app).
    cat > "$ENV_FILE" <<ENVEOF
# DevPush Configuration
# Generated by NixOS module - do not edit directly

# Service user
SERVICE_UID=$SERVICE_UID
SERVICE_GID=$SERVICE_GID

# Network
SERVER_IP=$SERVER_IP

# Application settings
APP_HOSTNAME=${cfg.settings.appHostname}
DEPLOY_DOMAIN=${cfg.settings.deployDomain}
LE_EMAIL=${cfg.settings.letsEncryptEmail}
CERT_CHALLENGE_PROVIDER=${cfg.settings.certChallengeProvider}

# Database
POSTGRES_DB=devpush
POSTGRES_USER=devpush-app
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# Secrets
ENCRYPTION_KEY=$ENCRYPTION_KEY
SECRET_KEY=$SECRET_KEY

# Resource limits
DEFAULT_CPUS=${toString cfg.settings.defaultCpus}
DEFAULT_MEMORY_MB=${toString cfg.settings.defaultMemoryMb}
MAX_CPUS=${toString cfg.settings.maxCpus}
MAX_MEMORY_MB=${toString cfg.settings.maxMemoryMb}
ALLOW_CUSTOM_RESOURCES=${if cfg.settings.allowCustomResources then "true" else "false"}

# Timeouts
JOB_TIMEOUT=${toString cfg.settings.jobTimeout}
DEPLOYMENT_TIMEOUT=${toString cfg.settings.deploymentTimeout}

# Branding
APP_NAME=${cfg.settings.appName}
${optionalString (cfg.settings.appDescription != null) "APP_DESCRIPTION=${cfg.settings.appDescription}"}
EMAIL_SENDER_NAME=${cfg.settings.emailSenderName}

# Logging
LOG_LEVEL=${cfg.settings.logLevel}
ENVEOF

${optionalString (cfg.extraEnv != {}) ''
    # Extra environment variables
    cat >> "$ENV_FILE" <<'EXTRAENVEOF'

# Extra configuration
${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "${name}=${value}") cfg.extraEnv)}
EXTRAENVEOF
''}

    # Append remaining user secrets (excluding ones we already handled)
    if [[ -f "$USER_SECRETS" ]]; then
      echo "" >> "$ENV_FILE"
      echo "# User-provided configuration" >> "$ENV_FILE"
      ${pkgs.gnugrep}/bin/grep -vE "^(ENCRYPTION_KEY|SECRET_KEY|POSTGRES_PASSWORD)=" "$USER_SECRETS" >> "$ENV_FILE" || true
    fi

    chmod 600 "$ENV_FILE"
    chown ${cfg.user}:${cfg.group} "$ENV_FILE"
  '';

  # Script to build runner images
  buildRunnersScript = pkgs.writeShellScript "devpush-build-runners" ''
    set -euo pipefail

    IMAGES_JSON="${cfg.package}/app/settings/images.json"
    RUNNER_DIR="${cfg.package}/docker/runner"

    if [[ ! -f "$IMAGES_JSON" ]]; then
      echo "No images.json found, skipping runner builds"
      exit 0
    fi

    ${pkgs.jq}/bin/jq -r '.[] | select(type=="object") | select(.slug and (.slug|type=="string")) | .slug' "$IMAGES_JSON" 2>/dev/null | while read -r slug; do
      [[ -n "$slug" ]] || continue

      DOCKERFILE="$RUNNER_DIR/Dockerfile.$slug"
      if [[ -f "$DOCKERFILE" ]]; then
        echo "Building runner image: $slug"
        ${pkgs.docker}/bin/docker build -f "$DOCKERFILE" -t "runner-$slug" "$RUNNER_DIR"
      else
        echo "Skipping $slug (no Dockerfile.$slug found)"
      fi
    done
  '';

  # Script to run database migrations
  migrateScript = pkgs.writeShellScript "devpush-migrate" ''
    set -euo pipefail

    STATUS_FILE="${cfg.dataDir}/.last-start-status"

    log_status() {
      echo "[$(date -Iseconds)] $1" >> "$STATUS_FILE"
      echo "$1"
    }

    # Wait for app container to be ready
    log_status "Waiting for app container..."
    CONTAINER=""
    for i in $(seq 1 30); do
      CONTAINER=$(${pkgs.docker}/bin/docker ps --filter "label=com.docker.compose.project=devpush" --filter "label=com.docker.compose.service=app" -q | head -1 || true)
      if [[ -n "$CONTAINER" ]]; then
        STATUS=$(${pkgs.docker}/bin/docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)
        if [[ "$STATUS" == "running" ]]; then
          break
        fi
      fi
      sleep 2
    done

    if [[ -z "$CONTAINER" ]]; then
      log_status "ERROR: App container not found after 60 seconds."
      log_status "Check container logs: docker compose -p devpush logs app"
      log_status "Check if containers are starting: docker ps -a | grep devpush"
      exit 1
    fi

    log_status "Running database migrations..."
    if ! ${pkgs.docker}/bin/docker exec "$CONTAINER" uv run alembic upgrade head 2>&1 | tee -a "$STATUS_FILE"; then
      log_status "ERROR: Database migration failed."
      log_status "This may indicate:"
      log_status "  - Database connection issues (wrong password?)"
      log_status "  - Schema conflicts from a previous version"
      log_status "  - Missing database initialization"
      log_status "Check postgres logs: docker compose -p devpush logs pgsql"
      exit 1
    fi

    log_status "Migrations completed successfully."
  '';

  # Script to validate state consistency
  validateStateScript = pkgs.writeShellScript "devpush-validate-state" ''
    set -euo pipefail

    SECRETS_DIR="${cfg.dataDir}/secrets"
    STRICT="${if cfg.strictStateValidation then "true" else "false"}"
    HAS_ERRORS=false

    warn() {
      echo "WARNING: $1" >&2
    }

    error() {
      echo "ERROR: $1" >&2
      HAS_ERRORS=true
    }

    # Check 1: Postgres password vs existing database volume
    USER_SECRETS="${cfg.secretsFile}"
    USER_PROVIDED_PASSWORD=false
    if [[ -f "$USER_SECRETS" ]] && ${pkgs.gnugrep}/bin/grep -qE "^POSTGRES_PASSWORD=" "$USER_SECRETS" 2>/dev/null; then
      USER_PROVIDED_PASSWORD=true
    fi

    if [[ -f "$SECRETS_DIR/postgres.password" ]]; then
      # Check if devpush-db volume exists (indicates prior database)
      if ${pkgs.docker}/bin/docker volume inspect devpush_devpush-db >/dev/null 2>&1; then
        CURRENT_HASH=$(${pkgs.coreutils}/bin/sha256sum "$SECRETS_DIR/postgres.password" | cut -d' ' -f1)
        STORED_HASH=""
        if [[ -f "$SECRETS_DIR/.postgres-password-hash" ]]; then
          STORED_HASH=$(cat "$SECRETS_DIR/.postgres-password-hash")
        fi

        if [[ -z "$STORED_HASH" ]]; then
          if [[ "$USER_PROVIDED_PASSWORD" == "true" ]]; then
            # User explicitly provided password - trust them
            echo "Note: Using user-provided POSTGRES_PASSWORD from secretsFile."
          else
            # Auto-generated password with no hash - likely a mismatch
            error "Database volume exists but no password hash on record."
            error "This may indicate the database was created with a different password"
            error "(e.g., from a previous .secrets file or manual setup)."
            error ""
            error "If you have the original password, add it to your secretsFile as POSTGRES_PASSWORD=..."
            error "Or delete the database volume to start fresh:"
            error "  docker volume rm devpush_devpush-db"
          fi
        elif [[ "$CURRENT_HASH" != "$STORED_HASH" ]]; then
          if [[ "$USER_PROVIDED_PASSWORD" == "true" ]]; then
            # User changed password intentionally - warn but allow
            warn "POSTGRES_PASSWORD in secretsFile differs from previously used password."
            warn "If this is intentional, you may need to update the database password manually."
          else
            error "Postgres password has changed but database volume exists."
            error "The database was created with a different password."
            error "Either restore the original secrets/postgres.password or delete the database volume:"
            error "  docker volume rm devpush_devpush-db"
          fi
        fi
      fi
    fi

    # Check 2: Encryption key consistency
    USER_PROVIDED_ENCRYPTION_KEY=false
    if [[ -f "$USER_SECRETS" ]] && ${pkgs.gnugrep}/bin/grep -qE "^ENCRYPTION_KEY=" "$USER_SECRETS" 2>/dev/null; then
      USER_PROVIDED_ENCRYPTION_KEY=true
    fi

    if [[ -f "$SECRETS_DIR/encryption.key" ]]; then
      # Only check if there's a database that might have encrypted data
      if ${pkgs.docker}/bin/docker volume inspect devpush_devpush-db >/dev/null 2>&1; then
        CURRENT_HASH=$(${pkgs.coreutils}/bin/sha256sum "$SECRETS_DIR/encryption.key" | cut -d' ' -f1)
        STORED_HASH=""
        if [[ -f "$SECRETS_DIR/.encryption-key-hash" ]]; then
          STORED_HASH=$(cat "$SECRETS_DIR/.encryption-key-hash")
        fi

        if [[ -z "$STORED_HASH" ]]; then
          if [[ "$USER_PROVIDED_ENCRYPTION_KEY" == "true" ]]; then
            # User explicitly provided key - trust them
            echo "Note: Using user-provided ENCRYPTION_KEY from secretsFile."
          else
            # Auto-generated key with no hash - warn about potential mismatch
            warn "Database exists but no encryption key hash on record."
            warn "If encrypted data exists, it may have been encrypted with a different key."
            warn "Ensure secrets/encryption.key matches the original, or data may be unreadable."
          fi
        elif [[ "$CURRENT_HASH" != "$STORED_HASH" ]]; then
          if [[ "$USER_PROVIDED_ENCRYPTION_KEY" == "true" ]]; then
            # User changed key intentionally - warn but allow
            warn "ENCRYPTION_KEY in secretsFile differs from previously used key."
            warn "Data encrypted with the old key will be unreadable."
          else
            error "Encryption key has changed but database exists with potentially encrypted data."
            error "Data encrypted with the old key will be unrecoverable."
            error "Restore the original secrets/encryption.key or start fresh:"
            error "  docker volume rm devpush_devpush-db"
          fi
        fi
      fi
    fi

    # Exit based on strict mode (before storing hashes!)
    if [[ "$HAS_ERRORS" == "true" ]]; then
      if [[ "$STRICT" == "true" ]]; then
        echo ""
        echo "State validation failed. Set strictStateValidation = false to override."
        exit 1
      else
        echo ""
        warn "State validation found issues but strictStateValidation is disabled."
        warn "Proceeding anyway - data corruption may occur."
      fi
    fi

    # Store current hashes for future runs (only after validation passes)
    if [[ -f "$SECRETS_DIR/postgres.password" ]]; then
      ${pkgs.coreutils}/bin/sha256sum "$SECRETS_DIR/postgres.password" | cut -d' ' -f1 > "$SECRETS_DIR/.postgres-password-hash"
      chmod 600 "$SECRETS_DIR/.postgres-password-hash"
      chown ${cfg.user}:${cfg.group} "$SECRETS_DIR/.postgres-password-hash"
    fi

    if [[ -f "$SECRETS_DIR/encryption.key" ]]; then
      ${pkgs.coreutils}/bin/sha256sum "$SECRETS_DIR/encryption.key" | cut -d' ' -f1 > "$SECRETS_DIR/.encryption-key-hash"
      chmod 600 "$SECRETS_DIR/.encryption-key-hash"
      chown ${cfg.user}:${cfg.group} "$SECRETS_DIR/.encryption-key-hash"
    fi
  '';

  # Script to create backup manifest
  createBackupManifestScript = pkgs.writeShellScript "devpush-create-backup-manifest" ''
    set -euo pipefail

    MANIFEST="${cfg.dataDir}/BACKUP.txt"

    # Only create if it doesn't exist (don't overwrite user modifications)
    if [[ ! -f "$MANIFEST" ]]; then
      cat > "$MANIFEST" <<'EOF'
DevPush Backup Checklist
========================

Back up these paths together - they are interdependent:

CRITICAL - Data is unrecoverable without these:
  secrets/                   - Encryption keys and database password
                               Without these, encrypted data cannot be decrypted
                               and the database cannot be accessed.

IMPORTANT - Service state:
  traefik/acme.json          - Let's Encrypt certificates
                               Can be regenerated, but rate limits apply.

  upload/                    - User-uploaded files

  Docker volume: devpush_devpush-db
                             - PostgreSQL database containing all application data


To back up the database:
  docker exec devpush-pgsql-1 pg_dump -U devpush-app devpush > backup.sql

To restore the database:
  cat backup.sql | docker exec -i devpush-pgsql-1 psql -U devpush-app devpush


Recovery procedure:
  1. Restore secrets/ directory FIRST (before starting services)
  2. Start services to create fresh database volume
  3. Stop services
  4. Restore database from backup
  5. Restore upload/ directory
  6. Restart services
EOF
      chmod 644 "$MANIFEST"
      chown ${cfg.user}:${cfg.group} "$MANIFEST"
    fi
  '';

in {
  options.services.devpush = {
    enable = mkEnableOption "DevPush deployment platform";

    package = mkOption {
      type = types.path;
      default = flake;
      defaultText = "flake source";
      description = "DevPush source package";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/devpush";
      description = "Directory for DevPush data";
    };

    logDir = mkOption {
      type = types.path;
      default = "/var/log/devpush";
      description = "Directory for DevPush logs";
    };

    user = mkOption {
      type = types.str;
      default = "devpush";
      description = "User account under which DevPush runs";
    };

    group = mkOption {
      type = types.str;
      default = "devpush";
      description = "Group under which DevPush runs";
    };

    settings = {
      appHostname = mkOption {
        type = types.str;
        description = "Hostname for the DevPush web interface (e.g., devpush.example.com)";
        example = "devpush.example.com";
      };

      deployDomain = mkOption {
        type = types.str;
        description = "Base domain for deployments (e.g., deploy.example.com)";
        example = "deploy.example.com";
      };

      letsEncryptEmail = mkOption {
        type = types.str;
        description = "Email address for Let's Encrypt certificate notifications";
        example = "admin@example.com";
      };

      serverIp = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Public IP address of the server. Auto-detected if null.";
        example = "203.0.113.10";
      };

      certChallengeProvider = mkOption {
        type = types.enum [ "default" "cloudflare" "route53" "gcloud" "digitalocean" "azure" ];
        default = "default";
        description = ''
          Certificate challenge provider for Let's Encrypt.
          - default: HTTP-01 challenge
          - cloudflare/route53/gcloud/digitalocean/azure: DNS-01 challenge

          For DNS providers, you must include the required environment variables
          in your secretsFile.
        '';
      };

      # Resource limits
      defaultCpus = mkOption {
        type = types.float;
        default = 0.5;
        description = "Default CPU limit for deployment containers.";
      };

      defaultMemoryMb = mkOption {
        type = types.int;
        default = 2048;
        description = "Default memory limit (MB) for deployment containers.";
      };

      maxCpus = mkOption {
        type = types.float;
        default = 4.0;
        description = "Maximum CPU limit for deployment containers.";
      };

      maxMemoryMb = mkOption {
        type = types.int;
        default = 8192;
        description = "Maximum memory limit (MB) for deployment containers.";
      };

      allowCustomResources = mkOption {
        type = types.bool;
        default = false;
        description = "Allow users to specify custom resource limits for their deployments.";
      };

      # Timeouts
      jobTimeout = mkOption {
        type = types.int;
        default = 320;
        description = "Timeout (seconds) for build jobs.";
      };

      deploymentTimeout = mkOption {
        type = types.int;
        default = 300;
        description = "Timeout (seconds) for deployment operations.";
      };

      # Branding
      appName = mkOption {
        type = types.str;
        default = "/dev/push";
        description = "Application name displayed in the UI.";
      };

      appDescription = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Application description displayed in the UI.";
      };

      emailSenderName = mkOption {
        type = types.str;
        default = "/dev/push";
        description = "Name used as the sender for outgoing emails.";
      };

      # Logging
      logLevel = mkOption {
        type = types.enum [ "DEBUG" "INFO" "WARNING" "ERROR" "CRITICAL" ];
        default = "WARNING";
        description = "Application log level.";
      };
    };

    secretsFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing secrets as environment variables.
        Must include:
        - GITHUB_APP_ID, GITHUB_APP_NAME, GITHUB_APP_PRIVATE_KEY
        - GITHUB_APP_WEBHOOK_SECRET, GITHUB_APP_CLIENT_ID, GITHUB_APP_CLIENT_SECRET
        - EMAIL_SENDER_ADDRESS, RESEND_API_KEY

        For DNS challenge providers, also include the provider-specific variables:
        - cloudflare: CF_DNS_API_TOKEN
        - route53: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
        - gcloud: GCE_PROJECT (and place gcloud-sa.json in dataDir)
        - digitalocean: DO_AUTH_TOKEN
        - azure: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID,
                 AZURE_TENANT_ID, AZURE_RESOURCE_GROUP
      '';
      example = "/run/secrets/devpush.env";
    };

    strictStateValidation = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Refuse to start if state inconsistencies are detected.

        When enabled, DevPush will fail to start if:
        - The postgres password has changed but the database volume exists
        - The encryption key has changed but encrypted data may exist

        Set to false to log warnings but attempt to start anyway.
      '';
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = ''
        Additional environment variables to include in the generated .env file.
        Use this for settings not covered by explicit options.
      '';
      example = {
        GOOGLE_CLIENT_ID = "your-client-id";
        AUTH_TOKEN_TTL_DAYS = "30";
      };
    };
  };

  config = mkIf cfg.enable {
    # Enable Docker
    virtualisation.docker.enable = true;

    # Create user and group
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      extraGroups = [ "docker" ];
      description = "DevPush service user";
    };

    users.groups.${cfg.group} = {};

    # Create directories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/traefik 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/upload 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.logDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    # Setup service (runs before main service)
    systemd.services.devpush-setup = {
      description = "DevPush setup (secrets, runners, env)";
      wantedBy = [ "multi-user.target" ];
      before = [ "devpush.service" ];
      after = [ "docker.service" "network-online.target" ];
      wants = [ "docker.service" "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "devpush-setup-exec" ''
          set -euo pipefail

          echo "Generating secrets..."
          ${generateSecretsScript}

          echo "Validating state consistency..."
          ${validateStateScript}

          echo "Building environment file..."
          ${buildEnvScript}

          echo "Creating backup manifest..."
          ${createBackupManifestScript}

          echo "Ensuring acme.json exists..."
          touch ${cfg.dataDir}/traefik/acme.json
          chmod 600 ${cfg.dataDir}/traefik/acme.json
          chown ${cfg.user}:${cfg.group} ${cfg.dataDir}/traefik/acme.json

          echo "Building runner images..."
          ${buildRunnersScript}

          echo "DevPush setup complete."
        '';
      };
    };

    # Main service
    systemd.services.devpush = {
      description = "DevPush deployment platform";
      wantedBy = [ "multi-user.target" ];
      after = [ "devpush-setup.service" "docker.service" "network-online.target" ];
      wants = [ "docker.service" "network-online.target" ];
      requires = [ "devpush-setup.service" ];

      environment = {
        COMPOSE_PROJECT_NAME = "devpush";
        # Host paths for docker-compose volume mounts
        DATA_DIR = cfg.dataDir;
        APP_DIR = cfg.package;
        LOG_DIR = cfg.logDir;
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 600;
        TimeoutStopSec = 600;

        ExecStart = pkgs.writeShellScript "devpush-start" ''
          set -euo pipefail

          STATUS_FILE="${cfg.dataDir}/.last-start-status"

          log_status() {
            echo "[$(date -Iseconds)] $1" >> "$STATUS_FILE"
            echo "$1"
          }

          # Clear status file for new start
          echo "# DevPush startup log - $(date -Iseconds)" > "$STATUS_FILE"
          chmod 640 "$STATUS_FILE"
          chown ${cfg.user}:${cfg.group} "$STATUS_FILE"

          log_status "Starting DevPush containers..."
          if ! ${pkgs.docker}/bin/docker compose \
            -p devpush \
            --env-file ${cfg.dataDir}/.env \
            ${composeFileArgs} \
            up -d --remove-orphans 2>&1 | tee -a "$STATUS_FILE"; then
            log_status "ERROR: Failed to start containers."
            log_status "Check docker compose config: docker compose -p devpush config"
            exit 1
          fi

          # Wait for app to be ready
          log_status "Waiting for app container to be ready..."
          APP_READY=false
          for i in $(seq 1 60); do
            CONTAINER=$(${pkgs.docker}/bin/docker ps --filter "label=com.docker.compose.project=devpush" --filter "label=com.docker.compose.service=app" -q | head -1 || true)
            if [[ -n "$CONTAINER" ]]; then
              STATUS=$(${pkgs.docker}/bin/docker inspect --format '{{.State.Status}}{{if .State.Health}}:{{.State.Health.Status}}{{end}}' "$CONTAINER" 2>/dev/null || true)
              case "$STATUS" in
                running:healthy|running)
                  log_status "App container is ready (status: $STATUS)."
                  APP_READY=true
                  break
                  ;;
              esac
            fi
            sleep 2
          done

          if [[ "$APP_READY" != "true" ]]; then
            log_status "WARNING: App container not ready after 120 seconds, proceeding with migrations anyway."
          fi

          # Run migrations
          ${migrateScript}

          log_status "DevPush started successfully."
        '';

        ExecStop = pkgs.writeShellScript "devpush-stop" ''
          set -euo pipefail

          echo "Stopping DevPush..."
          ${pkgs.docker}/bin/docker compose \
            -p devpush \
            --env-file ${cfg.dataDir}/.env \
            ${composeFileArgs} \
            stop

          echo "DevPush stopped."
        '';
      };
    };

    # Open firewall ports for HTTP/HTTPS
    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
