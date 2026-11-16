#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs INSIDE the chroot as root (enter.sh root), testing what a full
# development system needs: networking, Wi-Fi, packet-level tools, compilers,
# runtimes, debuggers and an SSH server. User-level checks run as USER via
# runuser (initgroups, so the aid_* groups apply).
#
#   enter.sh root 'sh /tmp/uburoot-advanced-test.sh ana' > log 2>&1
#
# The chroot shares Android's network namespace, so this script only reads
# network state or touches the phone itself, localhost and the default
# gateway (ping/ARP). It never changes iptables, routes or Wi-Fi modes and
# never scans other hosts. The one write is a dummy link that is added and
# removed at once, to see whether the user holds CAP_NET_ADMIN.
#
# Needs the packages installed by the app's dev profile (see the apt-get line
# in the report) and network access.
U=${1:-ana}
PASS=0
FAIL=0
OUT=/tmp/.uburoot-adv.out
W=/tmp/uburoot-adv
rm -rf "$W" && mkdir -p "$W" && chmod 777 "$W"
# enter.sh root starts in /root, which the user cannot read (spawned Python
# workers chdir() to the parent's cwd, for example).
cd /tmp || exit 1

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }
show() { sed 's/^/       | /' "$OUT" | tail -"${1:-6}"; }
# t "description" cmd...: pass when cmd succeeds.
t() {
    _d=$1
    shift
    if "$@" >"$OUT" 2>&1; then ok "$_d"; else bad "$_d" && show; fi
}
# info "description" cmd...: observation only, never fails the suite.
info() {
    _d=$1
    shift
    "$@" >"$OUT" 2>&1
    printf '  info %s (rc=%s)\n' "$_d" "$?"
    show 4
}
# as the user, with a login-like environment
asu() { runuser -u "$U" -- env HOME="/home/$U" USER="$U" PATH="$PATH" "$@"; }

section "identity"
t "running as root in the chroot" sh -c '[ "$(id -u)" = 0 ]'
t "user $U gets aid_inet via runuser" sh -c \
    "runuser -u $U -- id -Gn | tr ' ' '\n' | grep -qx aid_inet"
t "user $U is not in aid_net_raw/aid_net_admin" sh -c \
    "! runuser -u $U -- id -Gn | tr ' ' '\n' | grep -qE '^aid_net_(raw|admin)$'"
info "root capabilities (bounding set)" sh -c 'grep CapBnd /proc/self/status'
info "processes visible to the user (shared pid namespace)" asu sh -c \
    'echo "total=$(ps -e --no-headers | wc -l) system_server=$(pgrep -c system_server)"'

section "network state (shared with Android)"
IP4=$(ip -4 -o addr show wlan0 2>/dev/null | awk '{ sub("/.*", "", $4); print $4; exit }')
GW=$(ip route show table all 2>/dev/null | awk '/^default via/ && /dev wlan0/ { print $3; exit }')
t "wlan0 has an IPv4 address" test -n "$IP4"
t "default gateway found in Android's per-network table" test -n "$GW"
t "ip route get 1.1.1.1 (policy routing)" ip route get 1.1.1.1
info "main routing table (Android uses per-network tables)" sh -c 'ip route show table main | wc -l'
info "ip rule count" sh -c 'ip rule | wc -l'
t "ss sees Android's listening sockets (root)" sh -c '[ "$(ss -Htlnp | wc -l)" -gt 0 ]'

section "internet"
t "user: HTTPS IPv4" asu curl -4 -fsS --max-time 20 -o /dev/null https://cdimage.ubuntu.com/
info "user: HTTPS IPv6" asu curl -6 -fsS --max-time 10 -o /dev/null https://cdimage.ubuntu.com/
t "user: DNS via the system resolver (dig)" sh -c "runuser -u $U -- dig +short +time=5 ubuntu.com | grep -q ."
t "user: DNS straight to 1.1.1.1:53 (UDP)" sh -c "runuser -u $U -- dig +short +time=5 @1.1.1.1 ubuntu.com | grep -q ."
t "user: traceroute (UDP, 3 hops)" asu traceroute -n -m 3 -w 2 1.1.1.1
t "user: ping the gateway" asu ping -c 2 -W 3 "$GW"
info "user: download speed (35 MB Ubuntu Base tarball, bytes/s)" asu curl -fsS --max-time 120 -o /dev/null \
    -w '%{speed_download}\n' https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04.1-base-arm64.tar.gz

section "Wi-Fi (nl80211 and Android's wifi service)"
t "iw dev lists wlan0" sh -c 'iw dev | grep -q "Interface wlan0"'
# Print only link quality, never the SSID/BSSID.
t "iw link: connected" sh -c 'iw dev wlan0 link | grep -q "^Connected to"'
info "iw link: frequency and signal" sh -c 'iw dev wlan0 link | grep -E "freq|signal|tx bitrate"'
info "phy supported interface modes" sh -c 'iw phy | sed -n "/Supported interface modes/,/Band\|valid interface/p" | grep "\*"'
info "root: iw scan (driver may refuse while Android owns wlan0)" sh -c \
    'iw dev wlan0 scan 2>&1 | grep -c "^BSS" ; iw dev wlan0 scan 2>&1 | head -1'
t "user: iw scan is refused (no CAP_NET_ADMIN)" sh -c '! asu iw dev wlan0 scan >/dev/null 2>&1'
t "root: cmd wifi status (Android service)" sh -c 'cmd wifi status | grep -qi "wifi is enabled"'
info "root: cmd wifi list-scan-results (count)" sh -c 'cmd wifi list-scan-results | tail -n +2 | wc -l'

section "packet-level tools"
t "root: nmap -sS (raw SYN) localhost" sh -c "nmap -sS -p 1-10000 -T4 127.0.0.1 > $W/nmap-lo.txt"
info "  open on localhost" grep -E "^[0-9]+/" "$W/nmap-lo.txt"
t "root: nmap -sS the phone's own wlan0 address" nmap -sS --top-ports 200 -T4 "$IP4"
t "root: nmap -sU localhost (top 20)" nmap -sU --top-ports 20 -T4 127.0.0.1
t "root: nmap -sn gateway (ARP)" sh -c "nmap -sn $GW | grep -q 'Host is up'"
t "user: nmap -sT (connect scan) localhost" asu nmap -sT -p 1-1000 127.0.0.1
t "user: nmap --privileged -sS refused (no raw sockets)" sh -c "! runuser -u $U -- nmap --privileged -sS -p 1-100 127.0.0.1 >/dev/null 2>&1"
t "user: ping still works (ICMP datagram sockets)" asu ping -c 1 -W 3 "$GW"
t "root: tcpdump captures on wlan0" sh -c "
    (sleep 1; ping -c 3 -W 2 $GW >/dev/null 2>&1) &
    timeout 10 tcpdump -i wlan0 -nn -c 3 icmp 2>&1 | grep -q 'ICMP echo'"
t "root: tcpdump -i any" sh -c 'timeout 10 tcpdump -i any -nn -c 3 >/dev/null 2>&1'
t "user: tcpdump refused (cannot sniff the phone's traffic)" sh -c "! runuser -u $U -- timeout 5 tcpdump -i wlan0 -c 1 >/dev/null 2>&1"
t "user: cannot add links in the host netns (no CAP_NET_ADMIN)" sh -c \
    "! runuser -u $U -- ip link add ubutest0 type dummy 2>/dev/null"
ip link del ubutest0 2>/dev/null
t "user via sudo: tcpdump works" sh -c "runuser -u $U -- sudo -n timeout 10 tcpdump -i any -nn -c 1 >/dev/null 2>&1"
# scapy 2.7 imports every routing table. Android's table 1003 has
# "default dev dummy0", which wins the tie, and many entries carry source
# 0.0.0.0, so replies never come back. Fix scapy's own table (not the kernel's):
# keep routes with a real source, then add the active network's default.
info "scapy's route to 1.1.1.1 without help" python3 -c '
from scapy.all import conf; print(conf.route.route("1.1.1.1"))'
t "root: scapy ICMP to 1.1.1.1 (raw IP, scapy routes fixed)" python3 -c "
from scapy.all import IP, ICMP, sr1, conf
conf.verb = 0
conf.route.routes = [r for r in conf.route.routes if r[4] != '0.0.0.0' and not (r[0] == 0 and r[1] == 0)]
conf.route.invalidate_cache()
conf.route.add(net='0.0.0.0/0', gw='$GW', dev='wlan0')
r = sr1(IP(dst='1.1.1.1')/ICMP(), timeout=5)
assert r is not None and r[ICMP].type == 0"
t "root: scapy ARP to the gateway (layer 2)" python3 -c "
from scapy.all import ARP, Ether, srp1, conf
conf.verb = 0
r = srp1(Ether(dst='ff:ff:ff:ff:ff:ff')/ARP(pdst='$GW'), iface='wlan0', timeout=5)
assert r is not None"

section "servers and ports"
t "user: cannot bind port 80" sh -c '! asu python3 -c "import socket; socket.socket().bind((\"0.0.0.0\", 80))" 2>/dev/null'
t "root: can bind port 80" python3 -c 'import socket; socket.socket().bind(("0.0.0.0", 80))'
asu python3 -c '
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8099)); s.listen(1); s.settimeout(15)
c, _ = s.accept(); c.sendall(b"HELLO-FROM-UBUNTU\n"); c.close()' >/dev/null 2>&1 &
sleep 1
t "Android's toybox nc reaches a user server in the chroot" sh -c \
    'android toybox nc -w 5 127.0.0.1 8099 </dev/null | grep -q HELLO-FROM-UBUNTU'

section "firewall (read only; the netfilter tables are Android's)"
t "iptables-legacy -S sees Android's chains" sh -c 'iptables-legacy -S | grep -qE "bw_|fw_|oem_"'
if [ -n "$(cat /proc/net/ip_tables_names 2>/dev/null)" ]; then
    t "iptables points at legacy (Android's backend)" sh -c 'update-alternatives --query iptables | grep -q "^Value: /usr/sbin/iptables-legacy"'
    t "plain iptables -S sees Android's chains" sh -c 'iptables -S | grep -qE "bw_|fw_|oem_"'
fi
info "iptables/ip6tables alternatives" sh -c 'update-alternatives --query iptables | grep ^Value; update-alternatives --query ip6tables | grep ^Value'
info "kernel nf_tables support" sh -c '[ -r /proc/config.gz ] && gzip -dc /proc/config.gz | grep -E "^CONFIG_NF_TABLES="; ls /proc/net/netfilter 2>&1 | head -3'

section "compilers and runtimes (as the user)"
cat >"$W/hello.c" <<'EOF'
#include <stdio.h>
#include <pthread.h>
static void *run(void *a) { (void)a; return NULL; }
int main(void) { pthread_t t; pthread_create(&t, NULL, run, NULL); pthread_join(t, NULL); puts("c-ok"); return 0; }
EOF
cat >"$W/hello.cpp" <<'EOF'
#include <iostream>
#include <thread>
#include <filesystem>
int main() { std::thread t([] {}); t.join(); std::cout << "cpp-ok " << std::filesystem::current_path().string() << "\n"; }
EOF
mkdir -p "$W/cm" && cat >"$W/cm/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(h C)
add_executable(h ../hello.c)
EOF
cat >"$W/Hello.java" <<'EOF'
public class Hello { public static void main(String[] a) { System.out.println("java-ok " + Runtime.getRuntime().availableProcessors()); } }
EOF
cat >"$W/hello.go" <<'EOF'
package main
import ("fmt"; "net/http")
func main() { r, err := http.Get("https://cdimage.ubuntu.com/"); if err != nil { panic(err) }; fmt.Println("go-ok", r.StatusCode) }
EOF
chmod -R a+rwX "$W"
t "gcc: C with pthreads" asu sh -c "cd $W && gcc -O2 -pthread hello.c -o hc && ./hc | grep -q c-ok"
t "g++: C++17 threads + filesystem" asu sh -c "cd $W && g++ -std=c++17 -O2 -pthread hello.cpp -o hpp && ./hpp | grep -q cpp-ok"
t "cmake + make" asu sh -c "cd $W/cm && cmake -S . -B b >/dev/null && cmake --build b && ./b/h | grep -q c-ok"
t "gdb: run under ptrace" asu sh -c "cd $W && gcc -g hello.c -pthread -o hg && gdb -batch -ex run -ex bt ./hg 2>&1 | grep -q c-ok"
t "strace" asu sh -c "strace -f -e trace=openat -o $W/st.txt true && grep -q openat $W/st.txt"
t "python3: venv + pip install (requests)" asu sh -c "cd $W && python3 -m venv v && v/bin/pip -q install requests &&
    v/bin/python -c 'import requests; assert requests.get(\"https://cdimage.ubuntu.com/\", timeout=20).ok'"
cat >"$W/mp.py" <<'PY'
import multiprocessing as mp
def main():
    for m in ("fork", "spawn", "forkserver"):
        with mp.get_context(m).Pool(4) as p:
            assert p.map(abs, [-1, -2, -3]) == [1, 2, 3], m
if __name__ == "__main__":
    main()
PY
chmod 644 "$W/mp.py"
t "python3: multiprocessing fork/spawn/forkserver (/dev/shm semaphores)" asu sh -c "cd $W && timeout 60 python3 mp.py"
t "node + npm install" asu sh -c "cd $W && mkdir -p n && cd n && npm init -y >/dev/null &&
    npm install --silent is-number && node -e 'require(\"is-number\"); console.log(process.version)'"
t "go build (net/http over TLS)" asu sh -c "cd $W && go build -o hgo hello.go && ./hgo | grep -q 'go-ok 200'"
t "rust: cargo new + build + run" asu sh -c "cd $W && cargo new -q hr && cd hr && cargo build -q && ./target/debug/hr | grep -q 'Hello'"
t "java: javac + java (JIT)" asu sh -c "cd $W && javac Hello.java && java -cp . Hello | grep -q java-ok"
t "git: clone over HTTPS + commit" asu sh -c "cd $W && git clone -q --depth 1 https://github.com/octocat/Hello-World.git g &&
    cd g && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m test"
t "sqlite3" asu sh -c "echo 'create table t(x); insert into t values(42); select x from t;' | sqlite3 $W/db | grep -qx 42"
t "tmux session" asu sh -c "tmux -L ubutest new -d 'sleep 3' && tmux -L ubutest ls && tmux -L ubutest kill-server"

section "SSH server (for VS Code Remote, scp, etc.)"
mkdir -p /run/sshd
ssh-keygen -A >/dev/null 2>&1
rm -f /run/sshd-test.pid
/usr/sbin/sshd -p 8022 -o ListenAddress=127.0.0.1 -o PidFile=/run/sshd-test.pid >"$OUT" 2>&1
t "sshd starts (no systemd)" sh -c \
    'for i in 1 2 3 4 5 6 7 8 9 10; do [ -s /run/sshd-test.pid ] && exit 0; sleep 0.5; done; exit 1'
asu sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/ubutest* &&
    ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/ubutest &&
    cat ~/.ssh/ubutest.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' >/dev/null 2>&1
t "user: ssh -p 8022 with a key" asu ssh -p 8022 -i "/home/$U/.ssh/ubutest" -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$U@127.0.0.1" 'id -un'
[ -s /run/sshd-test.pid ] && kill "$(cat /run/sshd-test.pid)"
asu sh -c 'k=$(cat ~/.ssh/ubutest.pub) && grep -vxF "$k" ~/.ssh/authorized_keys > ~/.ssh/a.tmp;
    mv ~/.ssh/a.tmp ~/.ssh/authorized_keys; rm -f ~/.ssh/ubutest ~/.ssh/ubutest.pub'

section "limits that matter for dev tools"
t "inotify max_user_watches raised by mount.sh (>= 524288)" sh -c '[ "$(cat /proc/sys/fs/inotify/max_user_watches)" -ge 524288 ]'
info "user: open files limit (soft, hard)" asu sh -c 'echo "$(ulimit -Sn) $(ulimit -Hn)"'
info "PID 1 / systemd" sh -c 'echo "pid1=$(cat /proc/1/comm)"; systemctl is-system-running 2>&1 | head -1'
t "user: /dev/shm writable" asu sh -c "echo x > /dev/shm/ubutest && rm /dev/shm/ubutest"

rm -rf "$W" "$OUT"
printf '\nadvanced suite: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
