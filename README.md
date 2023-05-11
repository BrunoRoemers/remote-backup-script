# Remote Backup Script

This script makes an ssh connection to a server of choice, then creates a backup of a folder and/or a database of choice, and downloads it to your PC.

This script assumes that your ssh key is trusted by the server.

Check out the [example configuration file](configs/__template__.env).

Tested with servers from Combell.


## Features
- code backups
  - tar + gzip
- database backups
  - can detect database credentials of Joomla and Wordpress sites
  - can accept explicit database credentials
- backup the code only, or the database only, or both at the same time
- file-based configuration
  - create once, use and adapt many times
  - script asks which config to use every time
  - script asks for confirmation
  - all remote and local file paths are fully configurable
