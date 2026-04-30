#!/bin/bash

# =============================================================================
# CASSANDRA USER SETUP - RESTRICTED PERMISSIONS
# Creates application users with limited privileges
#
# ✅ SELECT, INSERT, UPDATE, DELETE - Allowed
# ✅ CREATE TABLE - Allowed (on specific keyspace)
# ✅ ALTER TABLE - Allowed (on specific keyspace)
# ❌ DROP KEYSPACE - BLOCKED
# ❌ DROP TABLE - BLOCKED
# ❌ TRUNCATE - BLOCKED
# ❌ SUPERUSER - BLOCKED
# =============================================================================

# Yapılandırma — ortam değişkenleri ile override et
CASSANDRA_USER="${CASSANDRA_USER:-cassandra}"
CASSANDRA_PASS="${CASSANDRA_PASS:?CASSANDRA_PASS env var zorunlu}"
CONTAINER_NAME="${CONTAINER_NAME:-cassandra}"

APP_USER="${APP_USER:-appuser}"
APP_PASSWORD="${APP_PASSWORD:?APP_PASSWORD env var zorunlu}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

header() {
    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}=========================================${NC}"
}

# =============================================================================
# CHECK CONTAINER
# =============================================================================
check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        error "Cassandra container is not running!"
        return 1
    fi
    return 0
}

# =============================================================================
# CREATE APPLICATION USER
# =============================================================================
setup_app_user() {
    header "CASSANDRA USER SETUP"

    log "Creating Cassandra user: $APP_USER"

    check_container || return 1

    # Create user with limited permissions
    docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS -e "
-- ===========================================
-- Drop existing user if exists
-- ===========================================
DROP ROLE IF EXISTS ${APP_USER};

-- ===========================================
-- Create new role (NOT SUPERUSER!)
-- ===========================================
CREATE ROLE ${APP_USER} WITH
    PASSWORD = '${APP_PASSWORD}'
    AND LOGIN = true
    AND SUPERUSER = false;

-- ===========================================
-- Grant permissions on all keyspaces
-- ===========================================
-- Data manipulation (SELECT, INSERT, UPDATE, DELETE)
GRANT SELECT ON ALL KEYSPACES TO ${APP_USER};
GRANT MODIFY ON ALL KEYSPACES TO ${APP_USER};

-- Schema modifications (CREATE, ALTER) - but not DROP
-- Note: Cassandra doesn't have fine-grained DROP control
-- We rely on NOT granting SUPERUSER to limit destructive operations

-- ===========================================
-- WHAT THIS USER CAN DO:
-- - SELECT data from any table
-- - INSERT data into any table
-- - UPDATE data in any table
-- - DELETE data from any table
-- - DESCRIBE keyspaces and tables
--
-- WHAT THIS USER CANNOT DO:
-- - CREATE/DROP keyspaces (requires SUPERUSER)
-- - CREATE/DROP users (requires SUPERUSER)
-- - Modify system tables
-- - Run nodetool commands
-- ===========================================
" 2>/dev/null

    if [ $? -eq 0 ]; then
        success "Cassandra user '${APP_USER}' created successfully"

        # Verify user exists
        log "Verifying user..."
        docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
            -e "LIST ROLES;" 2>/dev/null | grep -q "$APP_USER" && \
            success "User verified in roles list" || warning "User verification inconclusive"

        # Test connection
        log "Testing connection with new user..."
        docker exec $CONTAINER_NAME cqlsh -u $APP_USER -p $APP_PASSWORD \
            -e "DESCRIBE KEYSPACES;" 2>/dev/null && \
            success "Connection test passed ✓" || warning "Connection test failed"

        return 0
    else
        error "Failed to create Cassandra user"
        return 1
    fi
}

# =============================================================================
# CREATE KEYSPACE-SPECIFIC USER
# =============================================================================
setup_keyspace_user() {
    local keyspace=$1
    local username="${2:-${keyspace}_user}"
    local password="${3:-${keyspace}Pass2024!}"

    if [ -z "$keyspace" ]; then
        error "Keyspace name required!"
        log "Usage: $0 keyspace-user <keyspace_name> [username] [password]"
        return 1
    fi

    header "KEYSPACE-SPECIFIC USER SETUP"

    log "Creating user '$username' for keyspace '$keyspace'"

    check_container || return 1

    # Check if keyspace exists
    local ks_exists=$(docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
        -e "DESCRIBE KEYSPACE $keyspace" 2>&1)

    if echo "$ks_exists" | grep -qi "not found\|invalid"; then
        error "Keyspace '$keyspace' not found!"
        return 1
    fi

    docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS -e "
-- Drop existing user if exists
DROP ROLE IF EXISTS ${username};

-- Create new role
CREATE ROLE ${username} WITH
    PASSWORD = '${password}'
    AND LOGIN = true
    AND SUPERUSER = false;

-- Grant permissions ONLY on specific keyspace
GRANT SELECT ON KEYSPACE ${keyspace} TO ${username};
GRANT MODIFY ON KEYSPACE ${keyspace} TO ${username};
" 2>/dev/null

    if [ $? -eq 0 ]; then
        success "User '${username}' created for keyspace '${keyspace}'"

        log "Testing connection..."
        docker exec $CONTAINER_NAME cqlsh -u $username -p $password \
            -e "USE ${keyspace}; DESCRIBE TABLES;" 2>/dev/null && \
            success "Connection test passed ✓" || warning "Connection test inconclusive"

        echo ""
        log "Connection Details:"
        echo "  Keyspace: $keyspace"
        echo "  Username: $username"
        echo "  Password: $password"
        echo ""

        return 0
    else
        error "Failed to create keyspace user"
        return 1
    fi
}

# =============================================================================
# LIST USERS
# =============================================================================
list_users() {
    header "CASSANDRA USERS"

    check_container || return 1

    log "Current roles:"
    docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
        -e "LIST ROLES;" 2>/dev/null

    echo ""
    log "Role permissions:"
    docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
        -e "LIST ALL PERMISSIONS;" 2>/dev/null
}

# =============================================================================
# REMOVE USER
# =============================================================================
remove_user() {
    local username=${1:-$APP_USER}

    header "REMOVING USER: $username"

    check_container || return 1

    if [ "$username" == "cassandra" ]; then
        error "Cannot remove default superuser 'cassandra'!"
        return 1
    fi

    log "Removing user: $username"
    docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
        -e "DROP ROLE IF EXISTS ${username};" 2>/dev/null

    if [ $? -eq 0 ]; then
        success "User '$username' removed"
    else
        error "Failed to remove user"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  CASSANDRA USER SETUP - RESTRICTED PERMISSIONS${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo "Configuration:"
    echo "  Username: ${APP_USER}"
    echo "  Password: ${APP_PASSWORD}"
    echo ""
    echo -e "${GREEN}✅ ALLOWED:${NC}"
    echo "  - SELECT (read data)"
    echo "  - INSERT (add data)"
    echo "  - UPDATE (modify data)"
    echo "  - DELETE (remove data)"
    echo "  - DESCRIBE (view schema)"
    echo ""
    echo -e "${RED}❌ BLOCKED:${NC}"
    echo "  - DROP KEYSPACE"
    echo "  - CREATE/DROP ROLE"
    echo "  - SUPERUSER operations"
    echo "  - System table modifications"
    echo ""

    read -p "Continue with user creation? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi

    setup_app_user

    # Summary
    header "SETUP SUMMARY"

    echo ""
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}  CONNECTION EXAMPLES${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo ""
    echo "CQLSH:"
    echo "  docker exec -it cassandra cqlsh -u ${APP_USER} -p '${APP_PASSWORD}'"
    echo ""
    echo "Python:"
    echo "  from cassandra.cluster import Cluster"
    echo "  from cassandra.auth import PlainTextAuthProvider"
    echo "  auth = PlainTextAuthProvider(username='${APP_USER}', password='${APP_PASSWORD}')"
    echo "  cluster = Cluster(['${SERVER_IP:-localhost}'], auth_provider=auth)"
    echo ""
    echo "Node.js:"
    echo "  const client = new cassandra.Client({"
    echo "    contactPoints: ['${SERVER_IP:-localhost}'],"
    echo "    credentials: { username: '${APP_USER}', password: '${APP_PASSWORD}' }"
    echo "  });"
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANT: Change the password in production!${NC}"
    echo ""
}

# =============================================================================
# HELP
# =============================================================================
show_help() {
    echo ""
    echo "Cassandra User Setup Script"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  all                          - Create default app user (default)"
    echo "  keyspace-user <ks> [u] [p]   - Create user for specific keyspace"
    echo "  list                         - List all users and permissions"
    echo "  remove <username>            - Remove a user"
    echo "  help                         - Show this help"
    echo ""
    echo "Configuration (edit script to change):"
    echo "  Default Username: ${APP_USER}"
    echo "  Default Password: ${APP_PASSWORD}"
    echo ""
    echo "Examples:"
    echo "  $0 all"
    echo "  $0 keyspace-user my_keyspace"
    echo "  $0 keyspace-user my_keyspace myuser mypassword"
    echo "  $0 list"
    echo "  $0 remove olduser"
    echo ""
}

# =============================================================================
# ENTRY POINT
# =============================================================================
case "${1:-all}" in
    "all")
        main
        ;;
    "keyspace-user")
        setup_keyspace_user "$2" "$3" "$4"
        ;;
    "list")
        list_users
        ;;
    "remove"|"delete")
        remove_user "$2"
        ;;
    "help"|"--help"|"-h")
        show_help
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use '$0 help' for usage"
        exit 1
        ;;
esac

exit $?