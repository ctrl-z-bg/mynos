# nettools

Network commands for MyNOS: an SSH client and server that work with
OpenSSH, their keys, and small tools for TCP, DNS, the time and domains.

| Command | What it does |
|---|---|
| `ssh [-p PORT] [-l USER] [-i KEY] [-t\|-T] [USER@]HOST [COMMAND...]` | logs in to an SSH server: a shell, or a command |
| `sshd [-p PORT] [-v]` | the SSH server: others log in to MyNOS |
| `ssh-keygen [-f FILE] [-C COMMENT]` | a new Ed25519 key (`-y`: its public line, `-l`: its fingerprint) |
| `nc HOST PORT`, `nc -l PORT` | a TCP connection, typed into and printed |
| `dig NAME [TYPE] [@SERVER]` | a DNS question: A, AAAA, MX, TXT, NS, CNAME, SOA, PTR, ANY |
| `sntp [SERVER]` | an NTP server's time, and how far off MyNOS's clock is |
| `whois NAME` | who holds a domain (IANA, then the registry it names) |
| `portscan HOST [PORTS]` | which TCP ports answer (`22,80`, `1-1024`; common ones by default) |

The agent gets the tool `dns_lookup` (dig).

## SSH

Everything is in OCaml, the cryptography too, with one choice per
algorithm, the ones OpenSSH has preferred since 2014:

- key exchange **curve25519-sha256**, with OpenSSH's *strict kex* (the
  defence against the Terrapin attack);
- keys **ssh-ed25519**;
- cipher **chacha20-poly1305@openssh.com**.

Any OpenSSH from 6.5 on connects, and is connected to. The keys are
OpenSSH's files: a key made here works there and the other way round, as
long as it has no passphrase (not supported yet).

### Logging in to MyNOS

```
mkdir /disk/ssh
echo alice secret > /disk/ssh/passwd
sshd &
```

Then, from another machine: `ssh alice@MYNOS`. Who may log in:

- `/disk/ssh/passwd`: lines `USER PASSWORD`. The passwords are in clear,
  for now: anyone who can read the disk can read them.
- `/disk/ssh/authorized_keys`: OpenSSH's lines of public keys
  (`ssh-ed25519 AAAA... comment`), good for any user name. MyNOS has one
  user: whoever logs in has the whole system.

`sshd` makes its key, `/disk/ssh/ssh_host_ed25519_key`, the first time.
A session runs `sh` (or `sh -c COMMAND`) with a console of its own, as a
terminal window does. With a terminal (what `ssh` asks for when given no
command), the line is edited as in the window, and Ctrl-C ends the program
`sh` waits for. You get two minutes to log in, and six tries.

In QEMU, MyNOS is behind QEMU's network. To reach its port 22 from the
host, add a forwarding from QEMU's monitor:
`hostfwd_add n0 tcp:127.0.0.1:2222-:22` (`n0` is the network `tools/run-qemu.sh` gives MyNOS), then `ssh -p 2222 alice@127.0.0.1`.

### Logging in from MyNOS

```
ssh-keygen                         makes /disk/ssh/id_ed25519 and .pub
ssh alice@example.org
ssh -p 2222 alice@10.0.2.2 ls      a command
```

`ssh` tries `/disk/ssh/id_ed25519` and the keys given with `-i`, then asks
for the password. The first time it meets a server, it shows the server's
key and asks whether to trust it. If you answer yes, the key goes into
`/disk/ssh/known_hosts`. A server whose key has changed is refused. In a
shell, `~.` at the start of a line closes the connection.

## Speed

In QEMU with KVM on the reference PC, a key exchange takes a few
milliseconds and a whole `ssh` command about a second. Output comes at
about 500 KB/s, and input at under 100 KB/s, limited by the console.
Without KVM, or on a Raspberry Pi, everything is slower.
