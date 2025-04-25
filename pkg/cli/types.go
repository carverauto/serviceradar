package cli

import (
	"encoding/json"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/lipgloss"
)

// CmdConfig holds parsed command-line configuration.
type CmdConfig struct {
	Help            bool
	SubCmd          string
	ConfigFile      string
	AdminHash       string
	PollerFile      string
	Action          string
	Agent           string
	ServiceType     string
	ServiceName     string
	ServiceDetails  string
	ServicePort     int32
	EnableAllOnInit bool
	Args            []string
}
type model struct {
	passwordInput textinput.Model
	hash          string
	err           error
	focused       int
	copyMessage   string
	canCopy       bool
	quotes        []string
	styles        struct {
		focused, focused2, help, hint, success, error, hash, app lipgloss.Style
	}
}

// PollerConfig represents a subset of the poller configuration.
type PollerConfig struct {
	Agents       map[string]AgentConfig `json:"agents"`
	CoreAddress  string                 `json:"core_address"`
	ListenAddr   string                 `json:"listen_addr"`
	PollInterval string                 `json:"poll_interval"`
	PollerID     string                 `json:"poller_id"`
	ServiceName  string                 `json:"service_name"`
	ServiceType  string                 `json:"service_type"`
	Security     json.RawMessage        `json:"security,omitempty"`
}

// AgentConfig represents a subset of agent configuration.
type AgentConfig struct {
	Address  string          `json:"address"`
	Checks   []CheckConfig   `json:"checks"`
	Security json.RawMessage `json:"security,omitempty"`
}

// CheckConfig represents a service check configuration.
type CheckConfig struct {
	ServiceType string `json:"service_type"`
	ServiceName string `json:"service_name"`
	Details     string `json:"details,omitempty"`
	Port        int32  `json:"port,omitempty"`
}
