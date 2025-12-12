# ChainFlow-v2 Database Setup Guide

## 📊 Overview

ChainFlow-v2 uses **7 databases** across the microservices architecture:

### PostgreSQL (5 databases)
1. **chainflow_public_ledger** - Public economic ledger (EVAL + FUNDED)
2. **chainflow_account_manager** - Private user data, auth, KYC
3. **chainflow_system_manager** - Config, feature flags, service registry
4. **chainflow_risk_engine** - Risk monitoring and liquidations
5. **chainflow_market_manager** - Market metadata and schedules

### Scylla (1 cluster)
6. **chainflow_market_data** - Time-series market data (ticks, candles)

### Redis (1 instance)
7. **redis** - Caching for feature flags, rate limits, sessions

---

## 🚀 Quick Start (Development)

### 1. Start All Databases
```bash
./scripts/setup-databases.sh
```

This will:
- Start 5 PostgreSQL containers (ports 5432-5436)
- Start 1 Scylla container (port 9042)
- Start 1 Redis container (port 6379)
- Wait for all databases to be healthy
- Display connection details

### 2. Run Migrations
```bash
# SystemManager
cd SystemManager
make migrate-up

# AccountManager  
cd ../AccountManager
make migrate-up

# (Repeat for other services as they're built)
```

### 3. Stop Databases
```bash
# Stop (preserve data)
docker-compose -f docker-compose.dev.yml down

# Stop and remove all data
./scripts/teardown-databases.sh --remove-volumes
```

---

## 📝 Connection Details

### PostgreSQL Databases

| Database | Port | Connection String |
|----------|------|-------------------|
| PublicLedger | 5432 | `postgresql://postgres:postgres@localhost:5432/chainflow_public_ledger` |
| AccountManager | 5433 | `postgresql://postgres:postgres@localhost:5433/chainflow_account_manager` |
| SystemManager | 5434 | `postgresql://postgres:postgres@localhost:5434/chainflow_system_manager` |
| RiskEngine | 5435 | `postgresql://postgres:postgres@localhost:5435/chainflow_risk_engine` |
| MarketManager | 5436 | `postgresql://postgres:postgres@localhost:5436/chainflow_market_manager` |

**Default Credentials:**
- Username: `postgres`
- Password: `postgres`

### Scylla
- **CQL Port**: `9042`
- **Keyspace**: `chainflow_market_data` (created by migrations)
- **Connection**: `localhost:9042`

### Redis
- **URL**: `redis://localhost:6379`
- **Database**: `0` (default)

### pgAdmin (Database UI)
- **URL**: http://localhost:5050
- **Email**: `admin@chainflow.com`
- **Password**: `admin`

---

## 📊 Resource Requirements

### Development (Docker Desktop)
**Minimum:**
- **RAM**: 8 GB total
- **CPU**: 4 cores
- **Storage**: 50 GB

**Recommended:**
- **RAM**: 16 GB total
- **CPU**: 8 cores
- **Storage**: 100 GB SSD

### Production

#### PublicLedger (High Traffic)
- **CPU**: 4-8 cores
- **RAM**: 8-16 GB
- **Storage**: 100-500 GB SSD
- **Max Connections**: 200
- **Read Replicas**: 2-3

#### AccountManager (Sensitive Data)
- **CPU**: 2-4 cores
- **RAM**: 4-8 GB
- **Storage**: 50-100 GB SSD
- **Encryption**: At rest + in transit
- **Max Connections**: 100

#### SystemManager (Lightweight)
- **CPU**: 2 cores
- **RAM**: 2-4 GB
- **Storage**: 10-20 GB SSD
- **Max Connections**: 50

#### RiskEngine (Real-time)
- **CPU**: 4 cores
- **RAM**: 8 GB
- **Storage**: 50 GB SSD
- **Max Connections**: 100

#### MarketManager (Read-heavy)
- **CPU**: 2 cores
- **RAM**: 2 GB
- **Storage**: 10 GB SSD
- **Max Connections**: 50

#### Scylla Cluster (Time-series)
- **3-node cluster**
- **CPU per node**: 8 cores
- **RAM per node**: 16-32 GB
- **Storage per node**: 500 GB - 1 TB NVMe SSD
- **Replication Factor**: 3

---

## 🔧 Manual Setup (Without Docker)

### Install PostgreSQL 16
```bash
# Ubuntu/Debian
sudo apt install postgresql-16

# macOS
brew install postgresql@16
```

### Create Databases
```bash
# As postgres user
sudo -u postgres psql

-- Create databases
CREATE DATABASE chainflow_public_ledger;
CREATE DATABASE chainflow_account_manager;
CREATE DATABASE chainflow_system_manager;
CREATE DATABASE chainflow_risk_engine;
CREATE DATABASE chainflow_market_manager;

-- Create user (optional)
CREATE USER chainflow WITH PASSWORD 'your_secure_password';
GRANT ALL PRIVILEGES ON DATABASE chainflow_public_ledger TO chainflow;
-- Repeat for other databases
```

### Install Scylla
```bash
# See: https://www.scylladb.com/download/
# Or use Docker for development
docker run -d --name scylla -p 9042:9042 scylladb/scylla:5.4
```

### Install Redis
```bash
# Ubuntu/Debian
sudo apt install redis-server

# macOS
brew install redis
```

---

## 🧪 Testing Database Connections

### PostgreSQL
```bash
# Test connection
psql postgresql://postgres:postgres@localhost:5432/chainflow_public_ledger -c "SELECT version();"
```

### Scylla
```bash
# Test CQL connection
docker exec -it chainflow-scylla cqlsh
# Or if installed locally:
cqlsh localhost 9042
```

### Redis
```bash
# Test connection
redis-cli ping
# Should return: PONG
```

---

## 📦 Backup & Restore

### PostgreSQL Backup
```bash
# Backup single database
pg_dump -h localhost -p 5432 -U postgres chainflow_public_ledger > backup.sql

# Backup all databases
pg_dumpall -h localhost -U postgres > all_databases.sql

# Restore
psql -h localhost -U postgres chainflow_public_ledger < backup.sql
```

### Scylla Backup
```bash
# Snapshot
docker exec chainflow-scylla nodetool snapshot chainflow_market_data

# Backup files located in container at:
# /var/lib/scylla/data/chainflow_market_data/*/snapshots/
```

### Redis Backup
```bash
# Trigger save
redis-cli SAVE

# Backup RDB file (usually at /var/lib/redis/dump.rdb)
cp /var/lib/redis/dump.rdb backup_dump.rdb
```

---

## 🔍 Monitoring

### PostgreSQL
```bash
# Active connections
psql -c "SELECT count(*) FROM pg_stat_activity;"

# Database sizes
psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;"

# Slow queries
psql -c "SELECT * FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10;"
```

### Scylla
```bash
# Cluster status
docker exec chainflow-scylla nodetool status

# Table stats
docker exec chainflow-scylla nodetool tablestats chainflow_market_data
```

### Redis
```bash
# Memory usage
redis-cli INFO memory

# Connected clients
redis-cli INFO clients
```

---

## 🐛 Troubleshooting

### PostgreSQL won't start
```bash
# Check logs
docker logs chainflow-postgres-public-ledger

# Common issues:
# - Port already in use: Change port in docker-compose.dev.yml
# - Insufficient memory: Increase Docker resources
# - Volume permissions: Remove volumes and restart
```

### Scylla startup is slow
- **Normal**: Scylla takes 1-2 minutes to start
- **Wait**: Use the setup script which waits automatically
- **Check**: `docker logs chainflow-scylla`

### Connection refused errors
```bash
# Verify containers are running
docker ps

# Restart specific database
docker restart chainflow-postgres-system-manager

# Check health
docker inspect --format='{{.State.Health.Status}}' chainflow-postgres-system-manager
```

---

## 🔐 Security Notes

### Development
- Default credentials are used for convenience
- **DO NOT** use these in production
- All data is stored in Docker volumes

### Production
- Use strong passwords (minimum 32 characters)
- Enable SSL/TLS for all connections
- Restrict network access with firewalls
- Enable audit logging
- Implement backup encryption
- Use connection pooling with limits
- Enable database-level encryption at rest

---

## 📚 Additional Resources

- [PostgreSQL Documentation](https://www.postgresql.org/docs/16/)
- [Scylla Documentation](https://docs.scylladb.com/)
- [Redis Documentation](https://redis.io/docs/)
- [ChainFlow-v2 Database Schemas](./database-schemas/README.md)

---

**Last Updated**: 2025-11-16  
**Version**: 2.0.0
