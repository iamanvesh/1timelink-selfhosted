# 1TimeLink VPS Administration & Operations Guide

This guide details operations, debugging workflows, and security practices for administrators running the 1TimeLink stack on a single Linux VPS host.

---

## 1. Security & Privilege Model

To prevent security compromises, the 1TimeLink stack is installed and run under a dedicated, unprivileged system user (`onetimelink`).

* **Stack Owner**: The user `onetimelink` owns the deployment directory `/home/onetimelink/app/` and has exclusive read permissions (`600`) to the `.env` secret file.
* **Docker Permissions**: The `onetimelink` user belongs to the `docker` group, allowing it to interact with the Docker socket and manage swarm containers without needing `sudo` (root) permissions.

---

## 2. Accessing the Application Stack

### A. For System Administrators (Root/Sudoers)
System administrators can manage the stack or switch to the `onetimelink` user context without needing a password:

* **Switch context to app owner**:
  ```bash
  sudo -i -u onetimelink
  ```
* **Run Docker commands directly as admin**:
  ```bash
  sudo docker ps
  sudo docker service ps 1timelink_backend
  ```

### B. Delegating Developer/Operator Access
If you need to grant a developer or operations engineer access to manage the 1TimeLink application without giving them root credentials on the VPS host:
1. Obtain their public SSH key.
2. Append it to the `onetimelink` user's authorized keys file:
   ```bash
   sudo mkdir -p /home/onetimelink/.ssh
   sudo echo "ssh-rsa AAAAB3N..." >> /home/onetimelink/.ssh/authorized_keys
   sudo chown -R onetimelink:onetimelink /home/onetimelink/.ssh
   sudo chmod 700 /home/onetimelink/.ssh
   sudo chmod 600 /home/onetimelink/.ssh/authorized_keys
   ```
3. The developer can now SSH directly into the VPS as the unprivileged user:
   ```bash
   ssh onetimelink@your-vps-ip
   ```

---

## 3. Operational Runbook

All commands in this section should be executed as the `onetimelink` user (run `sudo -i -u onetimelink` first).

### Deploying / Updating the Stack
1. Navigate to the app directory:
   ```bash
   cd ~/app
   ```
2. Run the automated update script:
   ```bash
   ./update.sh
   ```

### Stopping the Stack
To tear down the active services and release resources:
```bash
docker stack rm 1timelink
```

### Checking Stack Status & Services
* **List active services**:
  ```bash
  docker stack services 1timelink
  ```
* **List running service containers (replicas)**:
  ```bash
  docker stack ps 1timelink
  ```

---

## 4. Debugging & Troubleshooting

### Viewing Service Logs
Swarm aggregates logs across all replicas. You can view them dynamically:
* **Backend API Logs**:
  ```bash
  docker service logs -f 1timelink_backend
  ```
* **Caddy Ingress Logs**:
  ```bash
  docker service logs -f 1timelink_ingress
  ```
* **Slack Message Relay Proxy Logs**:
  ```bash
  docker service logs -f 1timelink_slack-proxy
  ```

### Executing a Shell inside a Container
To inspect container environments, network connectivity, or file structures:
1. Find the local container ID:
   ```bash
   docker ps
   ```
2. Spawn an interactive shell inside the container:
   ```bash
   docker exec -it <container_id> /bin/sh
   ```

---

## 5. PostgreSQL Database Operations (Backup & Restore)

1TimeLink provides automated scripts to back up and restore your database using the S3/R2 storage configured in your `.env` file. These commands must be run under the `onetimelink` user context (run `sudo -i -u onetimelink` first).

### A. Database Backups (`backup.sh`)
An automated backup job is configured during installation to run **daily at 2 AM**. This script:
1. Dumps the host database locally using `pg_dump`.
2. Compresses the SQL dump using `gzip`.
3. Uploads the file securely to your configured S3/R2 bucket in the `db-backups/` prefix using the AWS CLI.
4. Cleans up the local temporary backup file to save disk space.

* **To run a manual backup immediately**:
  ```bash
  cd ~/app
  ./backup.sh
  ```

### B. Database Restores (`db_restore.sh`)
To restore your database to a specific snapshot state:
1. Log in to the VPS and switch to the app user:
   ```bash
   sudo -i -u onetimelink
   ```
2. Locate the backup filename from your S3/R2 bucket (e.g. `backup_2026-06-03_12-00-00.sql.gz`).
3. Run the restore script, passing the backup filename as an argument:
   ```bash
   cd ~/app
   ./db_restore.sh backup_2026-06-03_12-00-00.sql.gz
   ```
   *Note: This script will download the backup from S3, cleanly drop/re-create the existing database tables, and restore the schema and records.*

### C. Direct Console Inspection
To inspect the database tables directly from the host terminal:
```bash
sudo -u postgres psql -d onetimelink
```
Useful SQL queries:
* **Check workspace registration status**: `SELECT id, created_by, plan FROM workspace;`
* **Check database link payload count**: `SELECT count(*) FROM link;`
