# 🔗 GOOGLE DRIVE CONNECTION GUIDE

*[Türkçe](GOOGLE-DRIVE.tr.md) · **English***

## 📋 REQUIREMENTS

### 1. Technical Requirements:
- ✅ Linux server (Ubuntu, Debian, CentOS, etc.)
- ✅ Root or sudo privileges
- ✅ Internet connection
- ✅ Minimum 100MB free space (for rclone)
- ✅ Browser access (for configuration)

### 2. Google Account:
- ✅ Gmail account (free)
- ✅ Google Drive must be active
- ✅ Easier if you DON'T have 2FA (Two-Factor Authentication)
- ✅ "Less secure app" setting optional

---

## 🚀 STEP-BY-STEP SETUP

### STEP 1: Installing rclone (2 minutes)

On your Linux server:

```bash
# Install rclone automatically
curl https://rclone.org/install.sh | sudo bash

# Verify the installation
rclone version

# Sample output:
# rclone v1.64.2
# - os/version: ubuntu 22.04
# - arch: amd64
# - go: go1.21
```

**Alternative installation methods:**

```bash
# With APT for Debian/Ubuntu
sudo apt update
sudo apt install rclone -y

# With YUM for CentOS/RHEL
sudo yum install rclone -y

# Manual download (if you have internet problems)
cd /tmp
wget https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip rclone-current-linux-amd64.zip
cd rclone-*-linux-amd64
sudo cp rclone /usr/bin/
sudo chown root:root /usr/bin/rclone
sudo chmod 755 /usr/bin/rclone
```

---

### STEP 2: Google Drive Configuration (5-7 minutes)

#### 2.1. Start rclone Config

```bash
rclone config
```

#### 2.2. Create a New Remote

```
Current remotes:

Name                 Type
====                 ====

e) Edit existing remote
n) New remote
d) Delete remote
r) Rename remote
c) Copy remote
s) Set configuration password
q) Quit config
```

**Selection:** type `n` (New remote) and press Enter

---

#### 2.3. Remote Name

```
Enter name for new remote.
name>
```

**Type:** `gdrive` (or any name you like, e.g. `backup-drive`, `my-drive`)

**IMPORTANT:** You will use this name in scripts/sync-remote.sh!

---

#### 2.4. Storage Type Selection

```
Option Storage.
Type of storage to configure.
Choose a number from below, or type in your own value.
 1 / 1Fichier
   \ (fichier)
 2 / Akamai NetStorage
   \ (netstorage)
...
15 / Google Drive
   \ (drive)
...
45 / premiumize.me
   \ (premiumizeme)
Storage>
```

**Type:** `15` (or whatever number "drive" is on)

**Alternative:** You can type `drive` directly

---

#### 2.5. Google Application Client ID

```
Option client_id.
Google Application Client Id
Setting your own is recommended.
See https://rclone.org/drive/#making-your-own-client-id for how to create your own.
If you leave this blank, it will use an internal key which is low performance.
Enter a value. Press Enter to leave empty.
client_id>
```

**RECOMMENDATION:** Leave it blank (just press Enter)

**Note:** If you hit a performance problem later, you can create your own Client ID.

---

#### 2.6. Google Application Client Secret

```
Option client_secret.
OAuth Client Secret.
Leave blank normally.
Enter a value. Press Enter to leave empty.
client_secret>
```

**Type:** Leave it blank (just press Enter)

---

#### 2.7. Scope (Permission Level)

```
Option scope.
Comma separated list of scopes that rclone should use when requesting access from drive.
Choose a number from below, or type in your own string value.
Press Enter for the default (full access).
 1 / Full access all files, excluding Application Data Folder.
   \ (drive)
 2 / Read-only access to file metadata and file contents.
   \ (drive.readonly)
 3 / Access to files created by rclone only.
   \ (drive.file)
...
scope>
```

**Type:** `1` (Full access - required for backup)

---

#### 2.8. Root Folder ID

```
Option root_folder_id.
ID of the root folder.
Leave blank normally.
Enter a value. Press Enter to leave empty.
root_folder_id>
```

**Type:** Leave it blank (just press Enter)

---

#### 2.9. Service Account File

```
Option service_account_file.
Service Account Credentials JSON file path.
Leave blank normally.
Enter a value. Press Enter to leave empty.
service_account_file>
```

**Type:** Leave it blank (just press Enter)

---

#### 2.10. Advanced Config

```
Edit advanced config?
y) Yes
n) No (default)
y/n>
```

**Type:** `n` (No)

---

#### 2.11. Auto Config - VEEERY IMPORTANT! ⚠️

```
Use auto config?
 * Say Y if not sure
 * Say N if you are working on a remote or headless machine

y) Yes (default)
n) No
y/n>
```

**IMPORTANT:** It depends on your server's situation:

**CASE A:** Desktop Linux / graphical interface available → type `y`
**CASE B:** Remote server / connected over SSH / headless → type `n`

**Most of the time:** you will type `n` (because you are connected over SSH)

---

#### 2.12. REMOTE SERVER CASE (if you chose n)

At this step a LINK will appear on the screen:

```
Option config_token.
For this to work, you will need rclone available on a machine that has
a web browser available.

For more help and alternate methods see: https://rclone.org/remote_setup/

Execute the following on the machine with the web browser (same rclone
version recommended):

	rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"

Then paste the result below:
result>
```

**WHAT YOU DO NOW:**

1. **COPY this link:**
   ```bash
   rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"
   ```

2. **ON YOUR Windows COMPUTER (the one you are using right now):**

   **Open PowerShell and run it:**
   
   First install rclone on Windows:
   ```powershell
   # In PowerShell (as Administrator)
   choco install rclone
   # OR
   # download the Windows .exe from https://rclone.org/downloads/
   ```

   Then run the command:
   ```powershell
   rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"
   ```

3. **A BROWSER WILL OPEN:**
   - Choose your Google account
   - "rclone wants to access your Google Account" will appear
   - Click **Allow**

4. **SUCCESS MESSAGE:**
   ```
   Success!
   All done. Please go back to rclone.
   ```

5. **YOU WILL SEE A LONG CODE in PowerShell:**
   ```json
   {"access_token":"ya29.a0AfH6SMBx...","token_type":"Bearer",...}
   ```

6. **COPY THIS CODE IN FULL** (Ctrl+C)

7. **YOU GO BACK TO THE LINUX SERVER** (to your SSH terminal)

8. **PASTE THE CODE** and press Enter

```
result> {"access_token":"ya29.a0AfH6SMBx...","token_type":"Bearer",...}
```

---

#### 2.13. Team Drive

```
Configure this as a Shared Drive (Team Drive)?

y) Yes
n) No (default)
y/n>
```

**Type:** `n` (for personal use)

---

#### 2.14. Configuration Confirmation

```
Configuration complete.
Options:
- type: drive
- scope: drive
- token: {"access_token":"XXX","token_type":"Bearer",...}
- team_drive: 
Keep this "gdrive" remote?
y) Yes this is OK (default)
e) Edit this remote
d) Delete this remote
y/e/d>
```

**Type:** `y` (Yes)

---

#### 2.15. Exit

```
Current remotes:

Name                 Type
====                 ====
gdrive              drive

e) Edit existing remote
n) New remote
d) Delete remote
r) Rename remote
c) Copy remote
s) Set configuration password
q) Quit config
e/n/d/r/c/s/q>
```

**Type:** `q` (Quit)

---

### STEP 3: Testing (1 minute)

#### 3.1. Test the Connection

```bash
# List your Google Drive
rclone lsd gdrive:

# Sample output:
#           -1 2023-01-15 10:23:45        -1 My Drive
#           -1 2023-01-15 10:23:45        -1 Shared with me
```

✅ If the list showed up, SUCCESS!

#### 3.2. Create a Test Folder

```bash
# Create the DatabaseBackups folder
rclone mkdir gdrive:/DatabaseBackups

# Check
rclone lsd gdrive:
```

#### 3.3. Send a Test File

```bash
# Create a test file
echo "Test backup file" > /tmp/test-backup.txt

# Send it to Google Drive
rclone copy /tmp/test-backup.txt gdrive:/DatabaseBackups/

# Check
rclone ls gdrive:/DatabaseBackups/
```

Output:
```
       18 test-backup.txt
```

✅ If the file showed up, COMPLETE SUCCESS!

---

### STEP 4: Turn On Synchronization (30 seconds)

```bash
cd /opt/databases

# The settings now live in the .env file — do NOT EDIT the script.
sed -i 's/^REMOTE_SYNC_ENABLED=.*/REMOTE_SYNC_ENABLED=true/' .env
sed -i 's/^RCLONE_REMOTE_NAME=.*/RCLONE_REMOTE_NAME=gdrive/' .env

# Test it
./scripts/sync-remote.sh
```

---

## 🔒 SECURITY RECOMMENDATIONS

### 1. Encrypting the rclone Config (Optional but Recommended)

```bash
rclone config

# Choose from the menu:
s) Set configuration password

# Set a password
# You will enter this password every time you use rclone
```

### 2. Token Renewal

Google tokens are renewed periodically, automatically.  
If something goes wrong:

```bash
rclone config reconnect gdrive:
```

### 3. Two-Factor Authentication (2FA)

If your Google account has 2FA:
- rclone authorize will ask for a verification code
- Enter the code from your phone

---

## 🌐 CHECKING FROM THE WEB

1. Go to https://drive.google.com
2. Click "My Drive" in the left menu
3. You should see the "DatabaseBackups" folder
4. The backup files will be inside it

---

## ⚠️ POSSIBLE PROBLEMS AND SOLUTIONS

### Problem 1: "rclone: command not found"

```bash
# Install rclone again
curl https://rclone.org/install.sh | sudo bash

# PATH check
which rclone
# Output: /usr/bin/rclone
```

---

### Problem 2: "Failed to authorize"

**Cause:** No browser access, or the token was copied wrong

**Solution 1:** Install rclone on Windows and authorize there
```powershell
# Windows PowerShell
choco install rclone
rclone authorize "drive" "SUNUCUDAN_GELEN_KOD"
```
(SUNUCUDAN_GELEN_KOD = the code that came from the server)

**Solution 2:** Install rclone on another computer and authorize there

---

### Problem 3: "Token expired"

```bash
# Renew the token
rclone config reconnect gdrive:

# Or delete the remote and configure it again
rclone config delete gdrive
rclone config  # Start over
```

---

### Problem 4: "403 Forbidden" or "Rate limit exceeded"

**Cause:** Google API limits

**Solution:** Create your own Client ID

1. Go to https://console.cloud.google.com/
2. Create a new project
3. Enable the Google Drive API
4. Create OAuth 2.0 Credentials
5. Enter the Client ID and Secret into rclone config

---

### Problem 5: "Permission denied" during upload

```bash
# Test rclone
rclone lsd gdrive:

# Check the scope (it must be Full access)
rclone config show gdrive

# Authorize again
rclone config reconnect gdrive:
```

---

## 📊 GOOGLE DRIVE LIMITS

| Limit | Value |
|-------|-------|
| **Upload (daily)** | 750 GB/day |
| **Download (daily)** | 10 TB/day |
| **API request** | 20,000/100 seconds |
| **File size** | 5 TB/file |
| **Free space** | 15 GB |

**In your case:**
- Daily upload: ~620MB × 1 = 620MB
- Monthly: ~18GB

**Result:** You are within the limits ✅

---

## 💰 GOOGLE DRIVE PLANS

| Plan | Space | Price (Monthly) |
|------|------|---------------|
| **Free** | 15 GB | FREE |
| **Google One Basic** | 100 GB | $1.99 (~₺60) |
| **Google One Standard** | 200 GB | $2.99 (~₺90) |
| **Google One Premium** | 2 TB | $9.99 (~₺300) |

**Our suggestion for you:** the 100 GB plan ($1.99/month) ✅

---

## 🎯 SUMMARY CHECKLIST

Check these for a successful setup:

- [ ] rclone is installed (`rclone version` works)
- [ ] `rclone config` completed
- [ ] Remote name: `gdrive` (or the one you preferred)
- [ ] Scope: `drive` (Full access)
- [ ] Token obtained and pasted
- [ ] `rclone lsd gdrive:` works
- [ ] Test file was sent and shows up
- [ ] The file is there on the web at drive.google.com
- [ ] scripts/sync-remote.sh is executable
- [ ] REMOTE_SYNC_ENABLED="true"

**If all of them are ✅, YOU ARE READY!**

---

## 🚀 NEXT STEP

Now do the first real sync:

```bash
cd /opt/databases
./scripts/sync-remote.sh

# Watch the log
tail -f logs/remote_sync.log

# Check on Google Drive
rclone ls gdrive:/DatabaseBackups/
```

---

## 📞 HELP RESOURCES

- **rclone documentation:** https://rclone.org/drive/
- **Video tutorial:** search YouTube for "rclone google drive"
- **Troubleshooting:** https://rclone.org/drive/#troubleshooting
- **Forum:** https://forum.rclone.org/

---

**Setup Time:** 10-15 minutes  
**Difficulty:** ⭐⭐☆☆☆ (Easy)  
**Cost:** FREE (15GB) / $2/month (100GB)  

**LET'S GET STARTED!** 🚀
