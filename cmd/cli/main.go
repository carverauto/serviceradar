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

package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
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

type model struct {
	passwordInput textinput.Model
	costInput     textinput.Model
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

var (
	errEmptyPassword = fmt.Errorf("password cannot be empty")
	errInvalidCost   = fmt.Errorf("cost must be a number between %d and %d", minCost, maxCost)
	errHashFailed    = fmt.Errorf("failed to generate hash")
)

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

	ci := textinput.New()
	ci.Placeholder = fmt.Sprintf("Enter cost (%d-%d, default %d)", minCost, maxCost, defaultCost)
	ci.Width = 20
	ci.PromptStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(draculaCyan))
	ci.TextStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(draculaForeground))
	ci.PlaceholderStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(draculaComment))

	canCopy := true
	if err := clipboard.WriteAll(""); err != nil {
		canCopy = false
	}

	return &model{
		passwordInput: pi,
		costInput:     ci,
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
	} else if m.focused == focusedCost {
		m.costInput, cmd = m.costInput.Update(msg)
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
		m.costInput.Focus()
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
		m.costInput.Focus()
		m.focused = focusedCost

		return m, textinput.Blink
	}

	if m.focused == focusedCost {
		m.costInput.Blur()
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

	costStr := strings.TrimSpace(m.costInput.Value())

	cost := defaultCost

	if costStr != "" {
		var err error
		cost, err = strconv.Atoi(costStr)

		if err != nil || cost < minCost || cost > maxCost {
			m.err = errInvalidCost

			return m, nil
		}
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), cost)
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

	// Cost section
	costLabel := styles.focused2.Render("Cost Factor:")
	costSection := lipgloss.JoinVertical(
		lipgloss.Left,
		costLabel,
		m.costInput.View(),
	)
	content.WriteString(costSection + "\n\n")

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
		hintSection, // Use the pre-rendered hintSection
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

// cmdConfig holds parsed command-line configuration.
type cmdConfig struct {
	cost       int
	help       bool
	subCmd     string
	configFile string
	adminHash  string
	args       []string
}

// parseFlags parses command-line flags and subcommands.
func parseFlags() (cmdConfig, error) {
	// Default flags for bcrypt generation
	cost := flag.Int("cost", defaultCost, fmt.Sprintf("bcrypt cost factor (%d-%d)", minCost, maxCost))
	help := flag.Bool("help", false, "show help message")
	flag.Parse()

	cfg := cmdConfig{
		cost: *cost,
		help: *help,
		args: flag.Args(),
	}

	// Check for subcommand
	if len(os.Args) > 1 {
		cfg.subCmd = os.Args[1]
	}

	const (
		updateConfigSubCmd = "update-config"
	)

	// Parse update-config subcommand flags
	if cfg.subCmd == updateConfigSubCmd {
		updateConfigCmd := flag.NewFlagSet(updateConfigSubCmd, flag.ExitOnError)
		configFile := updateConfigCmd.String("file", "", "path to core.json config file")
		adminHash := updateConfigCmd.String("admin-hash", "", "bcrypt hash for admin user")

		if err := updateConfigCmd.Parse(os.Args[2:]); err != nil {
			return cfg, fmt.Errorf("parsing update-config flags: %w", err)
		}

		cfg.configFile = *configFile
		cfg.adminHash = *adminHash
	}

	return cfg, nil
}

// showHelp displays the help message and exits.
func showHelp() {
	fmt.Printf(`serviceradar: ServiceRadar command-line tool

Usage:
  serviceradar [options] [password]
  serviceradar update-config [options]

Commands:
  (default)        Generate bcrypt hash from password
  update-config    Update core.json with new admin password hash

Options for bcrypt generation:
  -cost int     bcrypt cost factor (%d-%d, default %d)
  -help         show this help message

Options for update-config:
  -file string        path to core.json config file
  -admin-hash string  bcrypt hash for admin user

Examples:
  # Generate bcrypt hash
  serviceradar -cost 14 mypassword
  echo mypassword | serviceradar
  serviceradar  # launches TUI

  # Update core.json
  serviceradar update-config -file /etc/serviceradar/core.json -admin-hash '$2a$12$...'
`, minCost, maxCost, defaultCost)
}

var (
	errRequiresFileAndHash = errors.New("update-config requires -file and -admin-hash")
	errUpdatingConfig      = errors.New("failed to update config file")
)

// runUpdateConfig handles the update-config subcommand.
func runUpdateConfig(configFile, adminHash string) error {
	if configFile == "" || adminHash == "" {
		return errRequiresFileAndHash
	}

	if err := updateConfig(configFile, adminHash); err != nil {
		return fmt.Errorf("%w: %s", errUpdatingConfig, err.Error())
	}

	fmt.Printf("Successfully updated %s\n", configFile)

	return nil
}

// runBcryptNonInteractive handles non-interactive bcrypt generation.
func runBcryptNonInteractive(cost int, args []string) error {
	password, err := getPasswordInput(args)
	if err != nil {
		return fmt.Errorf("reading password: %w", err)
	}

	hash, err := generateBcryptNonInteractive(password, cost)
	if err != nil {
		return fmt.Errorf("generating bcrypt hash: %w", err)
	}

	fmt.Println(hash)

	return nil
}

// runInteractive runs the TUI for interactive mode.
func runInteractive() error {
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	_, err := p.Run()

	return err
}

func main() {
	cfg, err := parseFlags()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if cfg.help {
		showHelp()
		os.Exit(0)
	}

	if cfg.subCmd == "update-config" {
		if err := runUpdateConfig(cfg.configFile, cfg.adminHash); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}

		os.Exit(0)
	}

	if len(cfg.args) > 0 || !isInputFromTerminal() {
		if err := runBcryptNonInteractive(cfg.cost, cfg.args); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}

		os.Exit(0)
	}

	if err := runInteractive(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func getPasswordInput(args []string) (string, error) {
	if len(args) > 0 {
		return strings.Join(args, " "), nil
	}

	if !isInputFromTerminal() {
		data, err := os.ReadFile("/dev/stdin")
		if err != nil {
			return "", err
		}

		return strings.TrimSpace(string(data)), nil
	}

	return "", nil
}

func isInputFromTerminal() bool {
	fileInfo, _ := os.Stdin.Stat()

	return (fileInfo.Mode() & os.ModeCharDevice) != 0
}

var (
	errConfigReadFailed    = errors.New("failed to read config file")
	errConfigMarshalFailed = errors.New("failed to serialize config")
	errConfigWriteFailed   = errors.New("failed to write config file")
	errInvalidAuthFormat   = errors.New("invalid auth configuration format")
)

// updateConfig updates the core.json file with a new admin bcrypt hash.
// updateConfig updates the core.json file with a new admin bcrypt hash while preserving
// duration fields in string format.
func updateConfig(configFile, adminHash string) error {
	// Read the existing config file
	data, err := os.ReadFile(configFile)
	if err != nil {
		return fmt.Errorf("%w %s: %w", errConfigReadFailed, configFile, err)
	}

	// Parse the JSON into a map
	var configMap map[string]interface{}
	if err := json.Unmarshal(data, &configMap); err != nil {
		return fmt.Errorf("%w: %w", errInvalidAuthFormat, err)
	}

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

	// DO NOT convert the config back to a struct and then to JSON
	// This would lose the string representation of durations

	// Marshal back to JSON with indentation
	updatedData, err := json.MarshalIndent(configMap, "", "    ")
	if err != nil {
		return fmt.Errorf("%w: %w", errConfigMarshalFailed, err)
	}

	// Write back to the file
	if err := os.WriteFile(configFile, updatedData, defaultFilePerms); err != nil {
		return fmt.Errorf("%w %s: %w", errConfigWriteFailed, configFile, err)
	}

	return nil
}

// updateConfigManual is a fallback method when core.LoadConfig fails.
// It preserves string duration fields like alert_threshold and jwt_expiration.
func updateConfigManual(configFile, adminHash string, data []byte) error {
	var configMap map[string]interface{}

	if err := json.Unmarshal(data, &configMap); err != nil {
		return fmt.Errorf("%w: %w", errInvalidAuthFormat, err)
	}

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

	// Marshal back to JSON with indentation
	updatedData, err := json.MarshalIndent(configMap, "", "    ")
	if err != nil {
		return fmt.Errorf("%w: %w", errConfigMarshalFailed, err)
	}

	// Write back to the file
	if err := os.WriteFile(configFile, updatedData, defaultFilePerms); err != nil {
		return fmt.Errorf("%w %s: %w", errConfigWriteFailed, configFile, err)
	}

	return nil
}
