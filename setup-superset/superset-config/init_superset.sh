#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -euo pipefail  # Improved: added -u (undefined variables) and -o pipefail

# ========================================
# Configuration & Constants
# ========================================

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly LOG_PREFIX="[Superset Init]"

# Bootstrap admin configuration (overridable via environment variables)
readonly ADMIN_USERNAME="${SUPERSET_ADMIN_USERNAME:-admin}"
readonly ADMIN_EMAIL="${SUPERSET_ADMIN_EMAIL:-admin@superset.com}"
readonly ADMIN_FIRSTNAME="${SUPERSET_ADMIN_FIRSTNAME:-Superset}"
readonly ADMIN_LASTNAME="${SUPERSET_ADMIN_LASTNAME:-Admin}"

# Artifacts directory configuration
readonly SUPERSET_ARTIFACTS_DIR="${SUPERSET_ARTIFACTS_DIR:-/app/setup-artifacts}"
readonly ADMIN_PASSWORD_FILE="${SUPERSET_ADMIN_PASSWORD_FILE:-${SUPERSET_ARTIFACTS_DIR%/}/generated_admin_password.txt}"

# Feature flags
readonly LOAD_EXAMPLES="${SUPERSET_LOAD_EXAMPLES:-no}"
readonly CYPRESS_MODE="${CYPRESS_CONFIG:-false}"

# ========================================
# Helper Functions
# ========================================

# Logging functions
log_info() {
    echo "${LOG_PREFIX} [INFO] $*" >&2
}

log_error() {
    echo "${LOG_PREFIX} [ERROR] $*" >&2
}

log_success() {
    echo "${LOG_PREFIX} [SUCCESS] $*" >&2
}

log_warning() {
    echo "${LOG_PREFIX} [WARNING] $*" >&2
}

# Print step header
echo_step() {
    local current_step=$1
    local total_steps=$2
    local status=$3
    local description=$4
    
    cat <<EOF

######################################################################
Init Step ${current_step}/${total_steps} [${status}] -- ${description}
######################################################################
EOF
}

# Calculate total steps based on configuration
get_total_steps() {
    if [[ "${LOAD_EXAMPLES}" == "yes" ]]; then
        echo 4
    else
        echo 3
    fi
}

# Generate a secure random password
generate_password() {
    python3 <<'PY'
import secrets
import string

def generate_secure_password(length=24):
    """Generate a secure random password."""
    alphabet = string.ascii_letters + string.digits + "!@#$%^&*"
    # Ensure password contains at least one of each type
    password = [
        secrets.choice(string.ascii_lowercase),
        secrets.choice(string.ascii_uppercase),
        secrets.choice(string.digits),
        secrets.choice("!@#$%^&*")
    ]
    # Fill the rest randomly
    password += [secrets.choice(alphabet) for _ in range(length - 4)]
    # Shuffle to avoid predictable patterns
    secrets.SystemRandom().shuffle(password)
    return ''.join(password)

print(generate_secure_password(24))
PY
}

# Setup admin password (generate or reuse)
setup_admin_password() {
    local admin_password="${SUPERSET_ADMIN_PASSWORD:-}"
    
    # Check if password is already set
    if [[ -n "${admin_password}" ]]; then
        log_info "Using admin password from environment variable"
        echo "${admin_password}"
        return 0
    fi
    
    # Check if password file exists and is not empty
    if [[ -f "${ADMIN_PASSWORD_FILE}" && -s "${ADMIN_PASSWORD_FILE}" ]]; then
        admin_password="$(cat "${ADMIN_PASSWORD_FILE}")"
        log_info "Reusing admin password from ${ADMIN_PASSWORD_FILE}"
        echo "${admin_password}"
        return 0
    fi
    
    # Generate new password
    log_info "Generating new admin password..."
    admin_password="$(generate_password)"
    
    # Save password to file
    if ! mkdir -p "$(dirname "${ADMIN_PASSWORD_FILE}")"; then
        log_error "Failed to create directory for password file"
        return 1
    fi
    
    if ! printf '%s' "${admin_password}" > "${ADMIN_PASSWORD_FILE}"; then
        log_error "Failed to write password to file"
        return 1
    fi
    
    chmod 600 "${ADMIN_PASSWORD_FILE}" 2>/dev/null || log_warning "Could not set strict permissions on password file"
    log_success "Generated and stored admin password at ${ADMIN_PASSWORD_FILE}"
    
    echo "${admin_password}"
}

# Configure Cypress test environment
configure_cypress_environment() {
    log_info "Configuring Cypress test environment"
    
    export SUPERSET_TESTENV=true
    export POSTGRES_DB=superset_cypress
    export SUPERSET__SQLALCHEMY_DATABASE_URI="postgresql+psycopg2://superset:superset@db:5432/superset_cypress"
    
    # Return fixed password for Cypress
    echo "general"
}

# Update existing admin user
update_admin_user() {
    local username=$1
    local password=$2
    local email=$3
    local firstname=$4
    local lastname=$5
    
    log_info "Updating existing admin user credentials..."
    
    superset shell <<PY
import os
import sys
from superset import app, security_manager
from superset.extensions import db

try:
    with app.app_context():
        user = security_manager.find_user(username="${username}")
        if not user:
            print("ERROR: Unable to locate admin user '${username}'", file=sys.stderr)
            sys.exit(1)
        
        user.email = "${email}"
        user.first_name = "${firstname}"
        user.last_name = "${lastname}"
        user.active = True
        user.password = security_manager.get_password_hash("${password}")
        
        db.session.commit()
        print(f"Successfully updated user '{username}'")
except Exception as e:
    print(f"ERROR: Failed to update user: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

# Run database migrations
run_db_migrations() {
    local step_num=$1
    local total_steps=$2
    
    echo_step "${step_num}" "${total_steps}" "Starting" "Applying DB migrations"
    
    if ! superset db upgrade; then
        log_error "Database migration failed"
        return 1
    fi
    
    echo_step "${step_num}" "${total_steps}" "Complete" "Applying DB migrations"
    return 0
}

# Create or update admin user
setup_admin_user() {
    local step_num=$1
    local total_steps=$2
    local username=$3
    local password=$4
    local email=$5
    local firstname=$6
    local lastname=$7
    
    echo_step "${step_num}" "${total_steps}" "Starting" "Setting up admin user (${username})"
    
    if [[ "${CYPRESS_MODE}" == "true" ]]; then
        log_info "Loading Cypress test users"
        if ! superset load_test_users; then
            log_error "Failed to load test users"
            return 1
        fi
    else
        # Try to create admin user
        if superset fab create-admin \
            --username "${username}" \
            --email "${email}" \
            --password "${password}" \
            --firstname "${firstname}" \
            --lastname "${lastname}" 2>/dev/null; then
            log_success "Admin user created successfully"
        else
            log_warning "Admin user already exists, updating credentials..."
            if ! update_admin_user "${username}" "${password}" "${email}" "${firstname}" "${lastname}"; then
                log_error "Failed to update admin user"
                return 1
            fi
        fi
    fi
    
    echo_step "${step_num}" "${total_steps}" "Complete" "Setting up admin user"
    return 0
}

# Initialize roles and permissions
setup_roles_and_permissions() {
    local step_num=$1
    local total_steps=$2
    
    echo_step "${step_num}" "${total_steps}" "Starting" "Setting up roles and permissions"
    
    if ! superset init; then
        log_error "Failed to initialize roles and permissions"
        return 1
    fi
    
    echo_step "${step_num}" "${total_steps}" "Complete" "Setting up roles and permissions"
    return 0
}

# Load example data
load_examples() {
    local step_num=$1
    local total_steps=$2
    
    echo_step "${step_num}" "${total_steps}" "Starting" "Loading examples"
    
    if [[ "${CYPRESS_MODE}" == "true" ]]; then
        log_info "Loading examples with test data for Cypress"
        if ! superset load_examples --load-test-data; then
            log_error "Failed to load examples with test data"
            return 1
        fi
    else
        log_info "Loading example datasets"
        if ! superset load_examples; then
            log_error "Failed to load examples"
            return 1
        fi
    fi
    
    echo_step "${step_num}" "${total_steps}" "Complete" "Loading examples"
    return 0
}

# ========================================
# Main Execution
# ========================================

main() {
    log_info "Starting Superset initialization"
    log_info "Script: ${SCRIPT_NAME}"
    
    # Run local bootstrap script if it exists
    if [[ -x /app/docker/docker-bootstrap.sh ]]; then
        log_info "Running local bootstrap script"
        if ! /app/docker/docker-bootstrap.sh; then
            log_error "Local bootstrap script failed"
            return 1
        fi
    else
        log_warning "Local bootstrap script not found or not executable"
    fi
    
    # Calculate total steps
    local total_steps
    total_steps=$(get_total_steps)
    log_info "Total initialization steps: ${total_steps}"
    
    # Setup admin password
    local admin_password
    if [[ "${CYPRESS_MODE}" == "true" ]]; then
        admin_password=$(configure_cypress_environment)
    else
        admin_password=$(setup_admin_password)
        if [[ -z "${admin_password}" ]]; then
            log_error "Failed to setup admin password"
            return 1
        fi
    fi
    
    # Export bootstrap variables for use by superset commands
    export SUPERSET_BOOTSTRAP_ADMIN_USERNAME="${ADMIN_USERNAME}"
    export SUPERSET_BOOTSTRAP_ADMIN_EMAIL="${ADMIN_EMAIL}"
    export SUPERSET_BOOTSTRAP_ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME}"
    export SUPERSET_BOOTSTRAP_ADMIN_LASTNAME="${ADMIN_LASTNAME}"
    export SUPERSET_BOOTSTRAP_ADMIN_PASSWORD="${admin_password}"
    
    # Step 1: Database migrations
    if ! run_db_migrations 1 "${total_steps}"; then
        return 1
    fi
    
    # Step 2: Setup admin user
    if ! setup_admin_user 2 "${total_steps}" \
        "${ADMIN_USERNAME}" \
        "${admin_password}" \
        "${ADMIN_EMAIL}" \
        "${ADMIN_FIRSTNAME}" \
        "${ADMIN_LASTNAME}"; then
        return 1
    fi
    
    # Step 3: Initialize roles and permissions
    if ! setup_roles_and_permissions 3 "${total_steps}"; then
        return 1
    fi
    
    # Step 4 (optional): Load examples
    if [[ "${LOAD_EXAMPLES}" == "yes" ]]; then
        if ! load_examples 4 "${total_steps}"; then
            return 1
        fi
    fi
    
    log_success "Superset initialization completed successfully!"
    log_info "Admin username: ${ADMIN_USERNAME}"
    log_info "Admin email: ${ADMIN_EMAIL}"
    
    if [[ "${CYPRESS_MODE}" != "true" ]]; then
        log_info "Admin password stored in: ${ADMIN_PASSWORD_FILE}"
    fi
    
    return 0
}

# Execute main function
if ! main; then
    log_error "Superset initialization failed"
    exit 1
fi

exit 0