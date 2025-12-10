# 🚴 Deploying Beefsteak

These are step-by-step instructions on how to deploy your own machine serving Beefsteak map tiles. We're assuming you're relatively comfortable in the terminal but aren't necessarily a sysadmin. These instruction come with no warranty as per the [MIT license](/LICENSE).

First things first, you'll need a beefy server. We use a dedicated [Hetzner](https://www.hetzner.com) box but there are many options on the market. The exact specs depend on your use case, but for production we recommend at minimum:

- 64GB RAM
- 2TB SSD
- Ubuntu 24

Once you've acquired a server and installed Ubuntu, open your terminal and `ssh` into it:

```
ssh root@the.server.ip.address
```

For security and compatibility, you'll probably want to run updates after a fresh Ubuntu install:

```
sudo apt update
sudo apt upgrade
reboot
```

(You'll need to `ssh` back in after the reboot.)

Next, install `git` if your distribution doesn't include it by default:

```
sudo apt update && sudo apt install -y git
```

Now, clone the Beefsteak repo onto your server:

```
git clone https://github.com/waysidemapping/beefsteak-map-tiles.git /usr/src/app
```

From here on it's recommended to use a terminal multiplexer like [`tmux`](https://github.com/tmux/tmux/wiki) to manage your session. This will ensure the setup and serve processes are not interrupted even if you get disconnected.

```
tmux new
```

You can detach from this session (type <key>Ctrl</key><key>B</key>, then <key>D</key>) or reattach (`tmux attach`) at any time.

Now you're ready to run the start script. This installs all the dependencies, sets up and loads the database with OSM data (this is the long part), and starts the tileserver. The whole process may take up to 24 hours depending on your machine. Run:

```
bash /usr/src/app/server/start.sh
```

## Troubleshooting

If your initial data import started but failed to complete, you may have incomplete data in your database. You'll need to drop the database before trying again:

```
sudo -u postgres psql --command="DROP DATABASE osm;"