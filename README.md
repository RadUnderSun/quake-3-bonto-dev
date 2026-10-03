# quake-3-bonto-dev

Create a container on [bonto.dev](bonto.dev), create an `install.sh` file, run `chmod +x install.sh`, and execute `./install.sh`; the server will then be running. You can modify settings and manage it - see below.

-------

* Check the status.

```
~/q3ded/q3ctl status
```

* View the logs.

```
~/q3ded/q3ctl logs
```

* Stop the server.

```
~/q3ded/q3ctl stop
```

* Start the server.

```
~/q3ded/q3ctl start
```

* Restart the server.

```
~/q3ded/q3ctl restart
```

## How to change settings

Here is the main file:

```
nano ~/q3ded/server.env
```

Edit the settings there, for example:

```
NET_SERVER_NAME=room.q3ded.local
HOSTNAME="Local Q3 Test"

MODE=duel
MAP=q3dm17
MAXCLIENTS=2
PORT=27960
```

For instance, if you want 4 players and a different map:

```
MAXCLIENTS=4
MAP=q3dm17
```

After making changes:

```
~/q3ded/q3ctl restart
```

## Faq
- Completely free
- It might work not only on Bonto but also anywhere you do *not* have root access and cannot change the container.
- I don't know how it works, but it works. No viruses.
- For questions, write to RadiantUnderSun@proton.me
