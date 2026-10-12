# Stands in for Hyprland's two sockets: .socket2.sock streams events, and sends configreloaded once the go file exists.
import os, socket, sys, threading, time

root, go = sys.argv[1], sys.argv[2]


def listen(name):
    path = os.path.join(root, name)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(4)
    return server


def commands(server):
    # The request socket answers every command with an empty body, which is all Quickshell's startup queries need.
    while True:
        conn, _ = server.accept()
        conn.recv(4096)
        conn.sendall(b"[]")
        conn.close()


def events(server):
    conn, _ = server.accept()
    conn.sendall(b"workspace>>1\n")
    while not os.path.exists(go):
        time.sleep(0.05)
    conn.sendall(b"configreloaded>>\n")
    time.sleep(60)


threading.Thread(target=commands, args=(listen(".socket.sock"),), daemon=True).start()
events(listen(".socket2.sock"))
