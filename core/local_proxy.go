package aauvcore

import (
	"errors"
	"io"
	"net"
	"strconv"
	"time"
)

func suggestLoopbackProxyPort() (int, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return 0, errors.New("local_proxy_port_unavailable")
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

// CheckLocalProxy verifies SOCKS5 username/password negotiation without opening
// an upstream connection or sending a model request.
func CheckLocalProxy(port int, user, password string) bool {
	if port < 1024 || port > 65535 || len(user) < 1 || len(user) > 255 || len(password) < 1 || len(password) > 255 {
		return false
	}
	conn, err := net.DialTimeout("tcp4", "127.0.0.1:"+strconv.Itoa(port), 250*time.Millisecond)
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(500 * time.Millisecond))
	var response [2]byte
	if _, err = conn.Write([]byte{5, 1, 2}); err != nil {
		return false
	}
	if _, err = io.ReadFull(conn, response[:]); err != nil || response != [2]byte{5, 2} {
		return false
	}
	message := append([]byte{1, byte(len(user))}, user...)
	message = append(message, byte(len(password)))
	message = append(message, password...)
	if _, err = conn.Write(message); err != nil {
		return false
	}
	_, err = io.ReadFull(conn, response[:])
	return err == nil && response == [2]byte{1, 0}
}
