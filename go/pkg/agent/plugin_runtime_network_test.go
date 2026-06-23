package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/gorilla/websocket"
)

func TestPluginWebSocketRecvAppliesReadLimit(t *testing.T) {
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade websocket: %v", err)
			return
		}
		defer func() { _ = conn.Close() }()

		if err := conn.WriteMessage(websocket.TextMessage, []byte(strings.Repeat("x", 65))); err != nil {
			t.Errorf("write oversized websocket message: %v", err)
		}
	}))
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")
	conn, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if resp != nil {
		defer func() { _ = resp.Body.Close() }()
	}
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}

	manager := NewPluginManager(context.Background(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer manager.Stop()

	exec := &pluginExecution{
		manager: manager,
		assignment: &pluginAssignment{
			AssignmentID: "ws-limit-test",
			PluginID:     "ws-limit-test",
			Capabilities: map[string]bool{"websocket_recv": true},
			Timeout:      time.Second,
		},
		wsConns:    make(map[uint32]*websocket.Conn),
		nextHandle: 1,
	}
	handle := exec.storeWSConn(conn)
	if handle == 0 {
		t.Fatalf("storeWSConn returned zero handle")
	}
	defer func() {
		if conn := exec.deleteWSConn(handle); conn != nil {
			_ = conn.Close()
		}
	}()

	if got := exec.hostWebSocketRecv(context.Background(), nil, handle, 0, 64, 1000); got != pluginErrTooLarge {
		t.Fatalf("hostWebSocketRecv = %d, want %d", got, pluginErrTooLarge)
	}
}
