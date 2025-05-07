/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package cli

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/atotto/clipboard"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"golang.org/x/crypto/bcrypt"
)

// Dracula theme colors.
const (
	defaultFilePerms  = 0600
	draculaForeground = "#F8F8F2"
	draculaCyan       = "#8BE9FD"
	draculaGreen      = "#50FA7B"
	draculaOrange     = "#FFB86C"
	draculaPink       = "#FF79C6"
	draculaPurple     = "#BD93F9"
	draculaRed        = "#FF5555"
	draculaYellow     = "#F1FA8C"
	draculaComment    = "#6272A4"
)

const (
	defaultCost      = 12
	minCost          = 4
	maxCost          = 31
	hashPadding      = 2
	hashPaddingSides = 4
	focusedPassword  = 0
	focusedCost      = 1
	focusedDone      = 2
)

// Styling with lipgloss (for TUI mode).
func newStyles() struct {
	focused, focused2, help, hint, success, error, hash, app lipgloss.Style
} {
	return struct {
		focused, focused2, help, hint, success, error, hash, app lipgloss.Style
	}{
		focused: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaPink)).
			Bold(true),
		focused2: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaYellow)),
		help: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaComment)),
		hint: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaOrange)),
		success: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaGreen)),
		error: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaRed)).
			Bold(true),
		hash: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaGreen)).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color(draculaPurple)),
		app: lipgloss.NewStyle().
			Padding(1, hashPadding).
			Border(lipgloss.DoubleBorder()).
			BorderForeground(lipgloss.Color(draculaCyan)).
			Foreground(lipgloss.Color(draculaForeground)),
	}
}

// Supported checker types.
const (
	typeProcess = "process"
	typePort    = "port"
	typeSNMP    = "snmp"
	typeICMP    = "icmp"
	typeSysMon  = "sysmon"
	typeRPerf   = "rperf-checker"
	typeDusk    = "dusk"
)

// Supported actions for update-poller.
const (
	actionAdd    = "add"
	actionRemove = "remove"
)

func getDefaultPorts() map[string]string {
	return map[string]string{
		typeSNMP:   ":50080",
		typeRPerf:  ":50081",
		typeDusk:   ":50082",
		typeSysMon: ":50083",
	}
}

func initialModel() *model {
	pi := textinput.New()
	pi.Placeholder = "Enter password"
	pi.EchoMode = textinput.EchoPassword
	pi.EchoCharacter = '•'
	pi.Focus()
	pi.Width = 40
	pi.PromptStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(draculaCyan))
	pi.TextStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(draculaForeground))
	pi.PlaceholderStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(draculaComment))

	canCopy := true
	if err := clipboard.WriteAll(""); err != nil {
		canCopy = false
	}

	return &model{
		passwordInput: pi,
		focused:       focusedPassword,
		canCopy:       canCopy,
		quotes:        []string{`"`, `"`},
		styles:        newStyles(),
	}
}

func (*model) Init() tea.Cmd {
	return textinput.Blink
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd

	if m.focused == focusedPassword {
		m.passwordInput, cmd = m.passwordInput.Update(msg)
	}

	if keyMsg, ok := msg.(tea.KeyMsg); ok {
		return m.handleKeyMsg(keyMsg, cmd)
	}

	return m, cmd
}

func (m *model) handleKeyMsg(msg tea.KeyMsg, cmd tea.Cmd) (tea.Model, tea.Cmd) {
	//nolint:exhaustive // Default case handles all unlisted keys
	switch msg.Type {
	case tea.KeyCtrlC, tea.KeyEsc:
		return m.quit()
	case tea.KeyEnter:
		return m.handleEnter(cmd)
	case tea.KeyTab:
		return m.handleTab(cmd)
	default:
		return m.handleDefault(msg, cmd)
	}
}

func (m *model) quit() (tea.Model, tea.Cmd) {
	return m, tea.Quit
}

func (m *model) handleEnter(cmd tea.Cmd) (tea.Model, tea.Cmd) {
	if m.focused == focusedPassword {
		m.passwordInput.Blur()
		m.focused = focusedCost

		return m, textinput.Blink
	}

	if m.focused == focusedCost {
		return m.generateHash()
	}

	return m, cmd
}

func (m *model) handleTab(cmd tea.Cmd) (tea.Model, tea.Cmd) {
	if m.focused == focusedPassword {
		m.passwordInput.Blur()
		m.focused = focusedCost

		return m, textinput.Blink
	}

	if m.focused == focusedCost {
		m.passwordInput.Focus()
		m.focused = focusedPassword

		return m, textinput.Blink
	}

	return m, cmd
}

func (m *model) handleDefault(msg tea.KeyMsg, cmd tea.Cmd) (tea.Model, tea.Cmd) {
	if m.focused == focusedDone && msg.String() == "c" && m.canCopy {
		if err := clipboard.WriteAll(m.hash); err != nil {
			m.copyMessage = "Failed to copy to clipboard"
		} else {
			m.copyMessage = "Hash copied to clipboard!"
		}
	}

	return m, cmd
}

func (m *model) generateHash() (tea.Model, tea.Cmd) {
	password := strings.TrimSpace(m.passwordInput.Value())
	if password == "" {
		m.err = errEmptyPassword

		return m, nil
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), defaultCost)
	if err != nil {
		m.err = fmt.Errorf("%w: %s", errHashFailed, err.Error())

		return m, nil
	}

	m.hash = string(hash)
	m.err = nil
	m.focused = focusedDone
	m.copyMessage = ""

	return m, nil
}

func (m *model) View() string {
	var content strings.Builder

	styles := m.styles

	// Title
	title := lipgloss.JoinHorizontal(
		lipgloss.Top,
		lipgloss.NewStyle().Foreground(lipgloss.Color(draculaPurple)).Render("🔒 "),
		styles.focused.Render("ServiceRadar CLI: Bcrypt Generator"),
	)

	content.WriteString(title + "\n\n")

	// Input or Result
	if m.focused < focusedDone {
		content.WriteString(m.renderInputView(&styles))
	} else {
		content.WriteString(m.renderResultView(&styles))
	}

	// Error
	if m.err != nil {
		content.WriteString("\n\n")
		content.WriteString(styles.error.Render(fmt.Sprintf("Error: %v", m.err)))
	}

	return styles.app.Align(lipgloss.Left).Render(content.String())
}

func (m *model) renderInputView(styles *struct {
	focused, focused2, help, hint, success, error, hash, app lipgloss.Style
}) string {
	var content strings.Builder

	// Password section
	passwordLabel := styles.focused2.Render("Password:")
	passwordSection := lipgloss.JoinVertical(
		lipgloss.Left,
		passwordLabel,
		m.passwordInput.View(),
	)
	content.WriteString(passwordSection + "\n\n")

	// Help
	content.WriteString(styles.help.Render("Enter → next field | Tab → switch field | Ctrl+C/Esc → quit"))

	return content.String()
}

func (m *model) renderResultView(styles *struct {
	focused, focused2, help, hint, success, error, hash, app lipgloss.Style
}) string {
	var content strings.Builder

	// Hash section
	hashLabel := styles.focused2.Render("Generated Bcrypt Hash:")
	displayHash := fmt.Sprintf("%s%s%s", m.quotes[0], m.hash, m.quotes[1])
	hashWidth := len(displayHash) + hashPaddingSides
	dynamicHashStyle := styles.hash.
		Width(hashWidth).
		Padding(0, hashPadding)
	hashBox := dynamicHashStyle.Render(displayHash)
	hashSection := lipgloss.JoinVertical(
		lipgloss.Left,
		hashLabel,
		hashBox,
	)
	content.WriteString(hashSection + "\n\n")

	// Hint and help
	hint := "Double-click to copy (or select and Ctrl+Shift+C)"
	if m.canCopy {
		hint = "Press C to copy (or select and Ctrl+Shift+C)"
	}

	hintSection := lipgloss.JoinVertical(
		lipgloss.Left,
		styles.hint.Render(hint),
		styles.help.Render("Ctrl+C/Esc → quit"),
	)

	if m.copyMessage != "" {
		hintSection = m.renderCopyMessage(hintSection, styles, hint)
	}

	content.WriteString(hintSection)

	return content.String()
}

func (m *model) renderCopyMessage(hintSection string, styles *struct {
	focused, focused2, help, hint, success, error, hash, app lipgloss.Style
}, _ string) string {
	messageStyle := styles.success
	if strings.HasPrefix(m.copyMessage, "Failed") {
		messageStyle = styles.error
	}

	return lipgloss.JoinVertical(
		lipgloss.Left,
		hintSection,
		messageStyle.Render(m.copyMessage),
	)
}

// generateBcryptNonInteractive handles non-interactive mode.
func generateBcryptNonInteractive(password string, cost int) (string, error) {
	if strings.TrimSpace(password) == "" {
		return "", errEmptyPassword
	}

	if cost < minCost || cost > maxCost {
		return "", errInvalidCost
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), cost)
	if err != nil {
		return "", fmt.Errorf("%w: %s", errHashFailed, err.Error())
	}

	return string(hash), nil
}

// SubcommandHandler defines the interface for parsing subcommand flags.
type SubcommandHandler interface {
	Parse(args []string, cfg *CmdConfig) error
}

// UpdateConfigHandler handles flags for the update-config subcommand.
type UpdateConfigHandler struct{}

func (UpdateConfigHandler) Parse(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("update-config", flag.ExitOnError)
	configFile := fs.String("file", "", "path to core.json config file")
	adminHash := fs.String("admin-hash", "", "bcrypt hash for admin user")
	dbPasswordFile := fs.String("db-password-file", "", "path to file containing database password (e.g., generated_password.txt)")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing update-config flags: %w", err)
	}

	cfg.ConfigFile = *configFile
	cfg.AdminHash = *adminHash
	cfg.DBPasswordFile = *dbPasswordFile

	return nil
}

// UpdatePollerHandler handles flags for the update-poller subcommand
type UpdatePollerHandler struct{}

func (UpdatePollerHandler) Parse(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("update-poller", flag.ExitOnError)
	pollerFile := fs.String("file", "", "path to poller.json config file")
	action := fs.String("action", "add", "action to perform: add or remove")
	agent := fs.String("agent", "local-agent", "agent name in poller.json")
	serviceType := fs.String("type", "", "service type (e.g., sysmon, rperf-checker, snmp)")
	serviceName := fs.String("name", "", "service name")
	serviceDetails := fs.String("details", "", "service details (e.g., IP:port for grpc)")
	enableAll := fs.Bool("enable-all", false, "enable all standard checkers")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing update-poller flags: %w", err)
	}

	cfg.PollerFile = *pollerFile
	cfg.Action = *action
	cfg.Agent = *agent
	cfg.ServiceType = *serviceType
	cfg.ServiceName = *serviceName
	cfg.ServiceDetails = *serviceDetails
	cfg.EnableAllOnInit = *enableAll

	return nil
}

// GenerateTLSHandler handles flags for the generate-tls subcommand
type GenerateTLSHandler struct{}

func (GenerateTLSHandler) Parse(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("generate-tls", flag.ExitOnError)
	ips := fs.String("ip", "", "IP addresses for the certificates (comma-separated)")
	certDir := fs.String("cert-dir", "/etc/serviceradar/certs", "where to store ServiceRadar certificates")
	protonDir := fs.String("proton-dir", "/etc/proton-server", "where to store Proton certificates")
	addIPs := fs.Bool("add-ips", false, "add IPs to existing certificates")
	nonInteractive := fs.Bool("non-interactive", false, "run in non-interactive mode (use 127.0.0.1)")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing generate-tls flags: %w", err)
	}

	cfg.IPS = *ips
	cfg.CertDir = *certDir
	cfg.ProtonDir = *protonDir
	cfg.AddIPs = *addIPs
	cfg.NonInteractive = *nonInteractive

	return nil
}

// ParseFlags parses command-line flags and subcommands
func ParseFlags() (*CmdConfig, error) {
	// Default flags for bcrypt generation
	help := flag.Bool("help", false, "show help message")
	flag.Parse()

	cfg := &CmdConfig{
		Help: *help,
		Args: flag.Args(),
	}

	// Check for subcommand
	if len(os.Args) > 1 {
		cfg.SubCmd = os.Args[1]
	}

	// Define subcommands and their handlers
	subcommands := map[string]SubcommandHandler{
		"update-config": UpdateConfigHandler{},
		"update-poller": UpdatePollerHandler{},
		"generate-tls":  GenerateTLSHandler{},
	}

	// Parse subcommand flags if present
	if handler, exists := subcommands[cfg.SubCmd]; exists {
		if err := handler.Parse(os.Args[2:], cfg); err != nil {
			return cfg, err
		}
	}

	return cfg, nil
}

// RunUpdatePoller handles the update-poller subcommand.
func RunUpdatePoller(cfg *CmdConfig) error {
	if err := validatePollerFile(cfg.PollerFile); err != nil {
		return err
	}

	if cfg.EnableAllOnInit {
		return enableAllCheckers(cfg.PollerFile, cfg.Agent)
	}

	if err := validateServiceType(cfg.ServiceType); err != nil {
		return err
	}

	// Normalize service type
	normalizedType := normalizeServiceType(cfg.ServiceType)

	// Validate action
	if err := validateAction(cfg.Action); err != nil {
		return err
	}

	// Prepare configuration
	serviceName := getServiceName(cfg.ServiceName, normalizedType)

	serviceDetails, err := getServiceDetails(cfg.ServiceDetails, normalizedType, serviceName)
	if err != nil {
		return fmt.Errorf("failed to determine service details: %w", err)
	}

	// Execute action
	if cfg.Action == actionAdd {
		return addChecker(cfg.PollerFile, cfg.Agent, normalizedType, serviceName, serviceDetails, cfg.ServicePort)
	}

	return removeChecker(cfg.PollerFile, cfg.Agent, normalizedType, serviceName)
}

// validatePollerFile checks if the poller file is specified.
func validatePollerFile(pollerFile string) error {
	if pollerFile == "" {
		return errRequiresPollerFile
	}

	return nil
}

// validateServiceType checks if the service type is provided.
func validateServiceType(serviceType string) error {
	if serviceType == "" {
		return errServiceTypeRequired
	}

	return nil
}

// validateAction checks if the action is supported.
func validateAction(action string) error {
	if action != actionAdd && action != actionRemove {
		return errUnsupportedAction
	}

	return nil
}

// getServiceName returns the service name, defaulting to the service type if not provided.
func getServiceName(serviceName, serviceType string) string {
	if serviceName == "" {
		return serviceType
	}

	return serviceName
}

// getServiceDetails determines the service details based on the service type.
func getServiceDetails(details, serviceType, serviceName string) (string, error) {
	if details != "" {
		return details, nil
	}

	// Get local IP address, default to localhost if unavailable
	ip, err := getLocalIP()
	if err != nil {
		ip = defaultIPAddress
	}

	// Check for default port in the defaultPorts map
	if port, ok := getDefaultPorts()[serviceType]; ok {
		return ip + port, nil
	}

	switch serviceType {
	case typeProcess:
		return serviceName, nil
	case typePort:
		return "127.0.0.1:22", nil
	case typeICMP:
		return "1.1.1.1", nil
	default:
		return "", fmt.Errorf("%w: %s", errNoDefaultDetails, serviceType)
	}
}

// writePollerConfig writes the updated configuration back to the file.
func writePollerConfig(pollerFile string, config *PollerConfig) error {
	updatedData, err := json.MarshalIndent(config, "", "    ")
	if err != nil {
		return fmt.Errorf("%w: %w", errUpdatingPollerConfig, err)
	}

	if err := os.WriteFile(pollerFile, updatedData, defaultFilePerms); err != nil {
		return fmt.Errorf("%w: %w", errUpdatingPollerConfig, err)
	}

	fmt.Printf("Successfully updated %s\n", pollerFile)
	fmt.Println("Remember to restart the ServiceRadar poller service:")
	fmt.Println("  systemctl restart serviceradar-poller")

	return nil
}

// RunUpdateConfig handles the update-config subcommand.
func RunUpdateConfig(configFile, adminHash, dbPasswordFile string) error {
	if configFile == "" {
		return errRequiresFileAndHash
	}

	if adminHash == "" && dbPasswordFile == "" {
		return errRequiresFileAndHash
	}

	if err := updateConfig(configFile, adminHash, dbPasswordFile); err != nil {
		return fmt.Errorf("%w: %s", errUpdatingConfig, err.Error())
	}

	fmt.Printf("Successfully updated %s\n", configFile)

	return nil
}

// RunGenerateTLS handles the generate-tls subcommand.
func RunGenerateTLS(cfg *CmdConfig) error {
	return GenerateTLSCerts(cfg)
}

// RunBcryptNonInteractive handles non-interactive bcrypt generation.
func RunBcryptNonInteractive(args []string) error {
	password, err := getPasswordInput(args)
	if err != nil {
		return fmt.Errorf("reading password: %w", err)
	}

	hash, err := generateBcryptNonInteractive(password, defaultCost)
	if err != nil {
		return fmt.Errorf("generating bcrypt hash: %w", err)
	}

	fmt.Println(hash)

	return nil
}

// RunInteractive runs the TUI for interactive mode.
func RunInteractive() error {
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	_, err := p.Run()

	return err
}

func getPasswordInput(args []string) (string, error) {
	if len(args) > 0 {
		return strings.Join(args, " "), nil
	}

	if !IsInputFromTerminal() {
		data, err := os.ReadFile("/dev/stdin")
		if err != nil {
			return "", err
		}

		return strings.TrimSpace(string(data)), nil
	}

	return "", nil
}

func IsInputFromTerminal() bool {
	fileInfo, _ := os.Stdin.Stat()

	return (fileInfo.Mode() & os.ModeCharDevice) != 0
}

// updateConfig updates the core.json file with a new admin bcrypt hash and/or database password while preserving
// duration fields in string format.
// updateConfig updates the core.json file with a new admin bcrypt hash and/or database password.
func updateConfig(configFile, adminHash, dbPasswordFile string) error {
	// Read and parse the existing config file
	configMap, err := readConfigFile(configFile)
	if err != nil {
		return err
	}

	// Update admin hash if provided
	if adminHash != "" {
		updateAdminHash(configMap, adminHash)
	}

	// Update database password if provided
	if dbPasswordFile != "" {
		if err := updateDatabasePassword(configMap, dbPasswordFile); err != nil {
			return fmt.Errorf("failed to update database password: %w", err)
		}
	}

	// Write the updated config back to the file
	if err := writeConfigFile(configFile, configMap); err != nil {
		return err
	}

	return nil
}

// readConfigFile reads and parses the core.json config file into a map.
func readConfigFile(configFile string) (map[string]interface{}, error) {
	data, err := os.ReadFile(configFile)
	if err != nil {
		return nil, fmt.Errorf("%w %s: %w", errConfigReadFailed, configFile, err)
	}

	var configMap map[string]interface{}

	if err := json.Unmarshal(data, &configMap); err != nil {
		return nil, fmt.Errorf("%w: %w", errInvalidAuthFormat, err)
	}

	return configMap, nil
}

// updateAdminHash updates the admin bcrypt hash in the config map.
func updateAdminHash(configMap map[string]interface{}, adminHash string) {
	// Ensure auth object exists
	auth, ok := configMap["auth"].(map[string]interface{})
	if !ok {
		auth = make(map[string]interface{})
		configMap["auth"] = auth
	}

	// Ensure local_users object exists
	localUsers, ok := auth["local_users"].(map[string]interface{})
	if !ok {
		localUsers = make(map[string]interface{})
		auth["local_users"] = localUsers
	}

	// Update admin hash
	localUsers["admin"] = adminHash
}

// updateDatabasePassword updates the database password in the config map.
func updateDatabasePassword(configMap map[string]interface{}, dbPasswordFile string) error {
	// Read password from file
	password, err := extractPasswordFromFile(dbPasswordFile)
	if err != nil {
		return err
	}

	// Ensure database object exists
	database, ok := configMap["database"].(map[string]interface{})
	if !ok {
		database = make(map[string]interface{})
		configMap["database"] = database
	}

	// Update database password
	database["password"] = password

	return nil
}

// extractPasswordFromFile reads and extracts the password from the password file.
func extractPasswordFromFile(dbPasswordFile string) (string, error) {
	data, err := os.ReadFile(dbPasswordFile)
	if err != nil {
		return "", fmt.Errorf("failed to read database password file %s: %w", dbPasswordFile, err)
	}

	// Extract password (assuming format: "Generated password: <password>")
	passwordLines := strings.Split(strings.TrimSpace(string(data)), "\n")
	for _, line := range passwordLines {
		if strings.HasPrefix(line, "Generated password:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "Generated password:")), nil
		}
	}

	return "", fmt.Errorf("%w: %s", errCantExtractPassword, dbPasswordFile)
}

// writeConfigFile writes the config map back to the file.
func writeConfigFile(configFile string, configMap map[string]interface{}) error {
	updatedData, err := json.MarshalIndent(configMap, "", "    ")
	if err != nil {
		return fmt.Errorf("%w: %w", errConfigMarshalFailed, err)
	}

	if err := os.WriteFile(configFile, updatedData, defaultFilePerms); err != nil {
		return fmt.Errorf("%w %s: %w", errConfigWriteFailed, configFile, err)
	}

	return nil
}
