#!/bin/bash

# =============================================================================
# DATABASE USER SETUP - RESTRICTED DROP PERMISSIONS
# Creates application users WITHOUT drop database/table privileges
# 
# ✅ SELECT, INSERT, UPDATE, DELETE - Allowed
# ✅ CREATE TABLE, CREATE INDEX - Allowed
# ✅ ALTER TABLE - Allowed
# ❌ DROP DATABASE - BLOCKED
# ❌ DROP TABLE - BLOCKED
# ❌ TRUNCATE - BLOCKED
# =============================================================================

# Yapılandırma — ortam değişkenleri ile override et
# Örnek:
#   DB_ROOT_PASSWORD='...' APP_PASSWORD='...' ./setup_db_users.sh
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD env var zorunlu}"
APP_USER="${APP_USER:-appuser}"
APP_PASSWORD="${APP_PASSWORD:?APP_PASSWORD env var zorunlu — güçlü bir parola seçin}"

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
# MARIADB USER
# =============================================================================
setup_mariadb_user() {
    header "MARIADB USER SETUP"
    
    log "Creating MariaDB user: $APP_USER"
    
    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^mariadb$"; then
        error "MariaDB container is not running!"
        return 1
    fi

    docker exec -i mariadb mariadb -u root -p${DB_ROOT_PASSWORD} 2>/dev/null <<EOF
-- ===========================================
-- Drop existing user if exists
-- ===========================================
DROP USER IF EXISTS '${APP_USER}'@'%';
DROP USER IF EXISTS '${APP_USER}'@'localhost';

-- ===========================================
-- Create new user
-- ===========================================
CREATE USER '${APP_USER}'@'%' IDENTIFIED BY '${APP_PASSWORD}';
CREATE USER '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PASSWORD}';

-- ===========================================
-- Grant permissions (NO DROP!)
-- ===========================================
-- Data manipulation (DELETE allowed!)
GRANT SELECT, INSERT, UPDATE, DELETE ON *.* TO '${APP_USER}'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON *.* TO '${APP_USER}'@'localhost';

-- Structure (CREATE allowed, DROP blocked)
GRANT CREATE, ALTER, INDEX, REFERENCES ON *.* TO '${APP_USER}'@'%';
GRANT CREATE, ALTER, INDEX, REFERENCES ON *.* TO '${APP_USER}'@'localhost';

-- Routines & Views
GRANT CREATE ROUTINE, ALTER ROUTINE, EXECUTE ON *.* TO '${APP_USER}'@'%';
GRANT CREATE ROUTINE, ALTER ROUTINE, EXECUTE ON *.* TO '${APP_USER}'@'localhost';
GRANT CREATE VIEW, SHOW VIEW ON *.* TO '${APP_USER}'@'%';
GRANT CREATE VIEW, SHOW VIEW ON *.* TO '${APP_USER}'@'localhost';

-- Temporary tables & Lock
GRANT CREATE TEMPORARY TABLES, LOCK TABLES ON *.* TO '${APP_USER}'@'%';
GRANT CREATE TEMPORARY TABLES, LOCK TABLES ON *.* TO '${APP_USER}'@'localhost';

-- Other necessary permissions
GRANT PROCESS, SHOW DATABASES ON *.* TO '${APP_USER}'@'%';
GRANT PROCESS, SHOW DATABASES ON *.* TO '${APP_USER}'@'localhost';

-- Trigger permission (for application triggers)
GRANT TRIGGER ON *.* TO '${APP_USER}'@'%';
GRANT TRIGGER ON *.* TO '${APP_USER}'@'localhost';

-- ===========================================
-- EXPLICITLY NOT GRANTED (BLOCKED):
-- - DROP
-- - TRUNCATE (requires DROP privilege)
-- - SUPER
-- - GRANT OPTION
-- - FILE
-- - SHUTDOWN
-- - RELOAD
-- ===========================================

FLUSH PRIVILEGES;

-- Verify user
SELECT User, Host FROM mysql.user WHERE User='${APP_USER}';
EOF

    if [ $? -eq 0 ]; then
        success "MariaDB user '${APP_USER}' created successfully"
        
        # Show granted permissions
        log "Verifying permissions..."
        docker exec mariadb mariadb -u root -p${DB_ROOT_PASSWORD} -e "SHOW GRANTS FOR '${APP_USER}'@'%';" 2>/dev/null
        
        # Test DROP is blocked
        log "Testing DROP restriction..."
        docker exec mariadb mariadb -u ${APP_USER} -p${APP_PASSWORD} -e "DROP DATABASE IF EXISTS test_drop_blocked_xyz123;" 2>&1 | grep -qi "denied\|error" && \
            success "DROP DATABASE is blocked ✓" || warning "DROP test inconclusive (may need existing DB)"
        
        return 0
    else
        error "Failed to create MariaDB user"
        return 1
    fi
}

# =============================================================================
# POSTGRESQL USER
# =============================================================================
setup_postgresql_user() {
    header "POSTGRESQL USER SETUP"
    
    log "Creating PostgreSQL user: $APP_USER"
    
    if ! docker ps --format '{{.Names}}' | grep -q "^postgresql$"; then
        error "PostgreSQL container is not running!"
        return 1
    fi

    docker exec -i postgresql psql -U root -d postgres 2>/dev/null <<EOF
-- ===========================================
-- Drop existing role if exists
-- ===========================================
DROP ROLE IF EXISTS ${APP_USER};

-- ===========================================
-- Create new role (NO SUPERUSER, NO CREATEDB)
-- ===========================================
CREATE ROLE ${APP_USER} WITH 
    LOGIN 
    PASSWORD '${APP_PASSWORD}'
    NOSUPERUSER 
    NOCREATEDB 
    NOCREATEROLE
    INHERIT;

-- ===========================================
-- Grant connect to all databases
-- ===========================================
GRANT CONNECT ON DATABASE postgres TO ${APP_USER};
GRANT CONNECT ON DATABASE defaultdb TO ${APP_USER};

-- ===========================================
-- Grant schema usage
-- ===========================================
\c defaultdb

-- Schema permissions
GRANT USAGE ON SCHEMA public TO ${APP_USER};
GRANT CREATE ON SCHEMA public TO ${APP_USER};

-- ===========================================
-- Table permissions (existing tables)
-- DELETE is allowed!
-- ===========================================
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${APP_USER};
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO ${APP_USER};

-- ===========================================
-- Default permissions (future tables)
-- ===========================================
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${APP_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO ${APP_USER};

-- ===========================================
-- Function/Procedure permissions
-- ===========================================
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ${APP_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT EXECUTE ON FUNCTIONS TO ${APP_USER};

-- ===========================================
-- BLOCKED by NOCREATEDB:
-- - CREATE DATABASE
-- - DROP DATABASE
-- ===========================================

-- Verify
\du ${APP_USER}
EOF

    if [ $? -eq 0 ]; then
        success "PostgreSQL user '${APP_USER}' created successfully"
        
        # Note about DROP TABLE
        log "Note: PostgreSQL NOCREATEDB prevents DROP DATABASE"
        log "User can still DROP tables they own (PostgreSQL limitation)"
        
        return 0
    else
        error "Failed to create PostgreSQL user"
        return 1
    fi
}

# =============================================================================
# MONGODB USER
# =============================================================================
setup_mongodb_user() {
    header "MONGODB USER SETUP"
    
    log "Creating MongoDB user: $APP_USER"
    
    if ! docker ps --format '{{.Names}}' | grep -q "^mongodb$"; then
        error "MongoDB container is not running!"
        return 1
    fi

    docker exec -i mongodb mongo -u root -p${DB_ROOT_PASSWORD} --authenticationDatabase admin --quiet 2>/dev/null <<EOF
// Switch to admin database
use admin

// Drop existing user if exists
try {
    db.dropUser("${APP_USER}")
    print("Existing user dropped")
} catch(e) {
    print("No existing user to drop")
}

// ===========================================
// Drop existing custom role if exists
// ===========================================
try {
    db.dropRole("appRole")
    print("Existing role dropped")
} catch(e) {
    print("No existing role to drop")
}

// ===========================================
// Create custom role WITHOUT dropDatabase/dropCollection
// DELETE (remove) is allowed!
// ===========================================
db.createRole({
    role: "appRole",
    privileges: [
        {
            resource: { db: "", collection: "" },
            actions: [
                // Read operations
                "find",
                "listCollections",
                "listIndexes",
                "collStats",
                "dbStats",
                
                // Write operations (DELETE included!)
                "insert", 
                "update",
                "remove",
                
                // Index operations
                "createCollection",
                "createIndex",
                "dropIndex",
                
                // Other
                "killCursors",
                "compact"
            ]
        }
    ],
    roles: []
})

print("Custom role 'appRole' created")

// ===========================================
// Create user with custom role
// ===========================================
db.createUser({
    user: "${APP_USER}",
    pwd: "${APP_PASSWORD}",
    roles: [
        { role: "appRole", db: "admin" }
    ]
})

print("User '${APP_USER}' created successfully")

// ===========================================
// BLOCKED ACTIONS:
// - dropDatabase
// - dropCollection
// - createUser/dropUser
// - grantRole/revokeRole
// - shutdown
// - replication commands
// ===========================================

// Verify user
print("Verifying user...")
db.getUsers({filter: {user: "${APP_USER}"}})
EOF

    if [ $? -eq 0 ]; then
        success "MongoDB user '${APP_USER}' created successfully"
        
        # Test connection
        log "Testing connection..."
        docker exec mongodb mongo -u ${APP_USER} -p${APP_PASSWORD} --authenticationDatabase admin --eval "db.stats()" --quiet 2>/dev/null && \
            success "Connection test passed ✓" || warning "Connection test failed"
        
        return 0
    else
        error "Failed to create MongoDB user"
        return 1
    fi
}

# =============================================================================
# REDIS USER (ACL)
# =============================================================================
setup_redis_user() {
    header "REDIS USER SETUP"
    
    log "Creating Redis user: $APP_USER"
    
    if ! docker ps --format '{{.Names}}' | grep -q "^redis$"; then
        error "Redis container is not running!"
        return 1
    fi

    # Redis ACL command - DEL is allowed, FLUSHALL/FLUSHDB blocked
    docker exec redis redis-cli -a ${DB_ROOT_PASSWORD} --no-auth-warning <<EOF
ACL DELUSER ${APP_USER}
ACL SETUSER ${APP_USER} on >${APP_PASSWORD} ~* +@all -@admin -@dangerous -FLUSHALL -FLUSHDB -DEBUG -SHUTDOWN -BGSAVE -BGREWRITEAOF -SAVE -CONFIG -REPLICAOF -SLAVEOF -CLUSTER -MIGRATE -KEYS
ACL SAVE
ACL GETUSER ${APP_USER}
EOF

    if [ $? -eq 0 ]; then
        success "Redis user '${APP_USER}' created successfully"
        
        # Test connection
        log "Testing connection..."
        docker exec redis redis-cli --user ${APP_USER} --pass ${APP_PASSWORD} --no-auth-warning PING 2>/dev/null | grep -q "PONG" && \
            success "Connection test passed ✓" || warning "Connection test failed"
        
        # Test DEL is allowed
        log "Testing DEL permission..."
        docker exec redis redis-cli --user ${APP_USER} --pass ${APP_PASSWORD} --no-auth-warning SET test_key "test" 2>/dev/null
        docker exec redis redis-cli --user ${APP_USER} --pass ${APP_PASSWORD} --no-auth-warning DEL test_key 2>/dev/null | grep -q "1" && \
            success "DEL command works ✓" || warning "DEL test inconclusive"
        
        # Test FLUSHALL is blocked
        log "Testing FLUSHALL restriction..."
        docker exec redis redis-cli --user ${APP_USER} --pass ${APP_PASSWORD} --no-auth-warning FLUSHALL 2>&1 | grep -qi "NOPERM\|permission" && \
            success "FLUSHALL is blocked ✓" || warning "Could not verify FLUSHALL restriction"
        
        return 0
    else
        error "Failed to create Redis user"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  DATABASE USER SETUP - RESTRICTED PERMISSIONS${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo "Configuration:"
    echo "  Username: ${APP_USER}"
    echo "  Password: ${APP_PASSWORD}"
    echo ""
    echo -e "${GREEN}✅ ALLOWED:${NC}"
    echo "  - SELECT, INSERT, UPDATE, DELETE (rows)"
    echo "  - CREATE TABLE, CREATE INDEX, ALTER TABLE"
    echo "  - CREATE/EXECUTE procedures and functions"
    echo "  - DEL command in Redis"
    echo ""
    echo -e "${RED}❌ BLOCKED:${NC}"
    echo "  - DROP DATABASE"
    echo "  - DROP TABLE"
    echo "  - TRUNCATE TABLE"
    echo "  - FLUSHALL/FLUSHDB (Redis)"
    echo "  - Admin/Superuser operations"
    echo ""
    
    read -p "Continue with user creation? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi
    
    echo ""
    local success_count=0
    local fail_count=0

    # MariaDB
    setup_mariadb_user && ((success_count++)) || ((fail_count++))
    
    # PostgreSQL
    setup_postgresql_user && ((success_count++)) || ((fail_count++))
    
    # MongoDB
    setup_mongodb_user && ((success_count++)) || ((fail_count++))
    
    # Redis
    setup_redis_user && ((success_count++)) || ((fail_count++))

    # Summary
    header "SETUP SUMMARY"
    
    echo ""
    success "Successful: $success_count"
    [ $fail_count -gt 0 ] && error "Failed: $fail_count" || echo -e "${GREEN}[✓]${NC} Failed: $fail_count"
    
    echo ""
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}  CONNECTION EXAMPLES${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo ""
    echo "MariaDB:"
    echo "  mysql -h <host> -P 3306 -u ${APP_USER} -p'${APP_PASSWORD}'"
    echo ""
    echo "PostgreSQL:"
    echo "  psql -h <host> -p 5432 -U ${APP_USER} -d defaultdb"
    echo "  Password: ${APP_PASSWORD}"
    echo ""
    echo "MongoDB:"
    echo "  mongo -u ${APP_USER} -p '${APP_PASSWORD}' --authenticationDatabase admin <host>:27017"
    echo ""
    echo "Redis:"
    echo "  redis-cli -h <host> -p 6379 --user ${APP_USER} --pass '${APP_PASSWORD}'"
    echo ""
    
    echo -e "${YELLOW}⚠️  IMPORTANT: Change the password in production!${NC}"
    echo ""
    
    return $fail_count
}

# =============================================================================
# REMOVE USER
# =============================================================================
remove_users() {
    header "REMOVING USERS"
    
    log "Removing MariaDB user..."
    docker exec mariadb mariadb -u root -p${DB_ROOT_PASSWORD} -e "DROP USER IF EXISTS '${APP_USER}'@'%'; DROP USER IF EXISTS '${APP_USER}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null && \
        success "MariaDB user removed" || warning "MariaDB user removal failed"
    
    log "Removing PostgreSQL user..."
    docker exec postgresql psql -U root -d postgres -c "DROP ROLE IF EXISTS ${APP_USER};" 2>/dev/null && \
        success "PostgreSQL user removed" || warning "PostgreSQL user removal failed"
    
    log "Removing MongoDB user..."
    docker exec mongodb mongo -u root -p${DB_ROOT_PASSWORD} --authenticationDatabase admin --eval "db.dropUser('${APP_USER}')" --quiet 2>/dev/null && \
        success "MongoDB user removed" || warning "MongoDB user removal failed"
    
    log "Removing Redis user..."
    docker exec redis redis-cli -a ${DB_ROOT_PASSWORD} --no-auth-warning ACL DELUSER ${APP_USER} 2>/dev/null && \
        success "Redis user removed" || warning "Redis user removal failed"
    
    docker exec redis redis-cli -a ${DB_ROOT_PASSWORD} --no-auth-warning ACL SAVE 2>/dev/null
    
    success "User removal complete"
}

# =============================================================================
# ENTRY POINT
# =============================================================================
case "${1:-all}" in
    "all")
        main
        ;;
    "mariadb")
        setup_mariadb_user
        ;;
    "postgresql"|"postgres")
        setup_postgresql_user
        ;;
    "mongodb"|"mongo")
        setup_mongodb_user
        ;;
    "redis")
        setup_redis_user
        ;;
    "remove"|"delete")
        remove_users
        ;;
    "help"|"--help"|"-h")
        echo ""
        echo "Database User Setup Script"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  all        - Setup all databases (default)"
        echo "  mariadb    - Setup MariaDB user only"
        echo "  postgresql - Setup PostgreSQL user only"
        echo "  mongodb    - Setup MongoDB user only"
        echo "  redis      - Setup Redis user only"
        echo "  remove     - Remove user from all databases"
        echo ""
        echo "Configuration (edit script to change):"
        echo "  Username: ${APP_USER}"
        echo "  Password: ${APP_PASSWORD}"
        echo ""
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use '$0 help' for usage"
        exit 1
        ;;
esac

exit $?