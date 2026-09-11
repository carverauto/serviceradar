package main

import (
	"bytes"
	"fmt"
	"strings"
	"text/template"
)

// serviceName must match go/cmd/agent's Windows service name.
const serviceName = "ServiceRadarAgent"

type wxsValues struct{ MSIVersion, UpgradeCode, AgentPath, ConfigPath string }

// The service is installed to start automatically but is not started by the
// installer: the default config names a placeholder gateway and certificates,
// so the operator configures it first. Failure delays are milliseconds; the
// reset period is seconds. The config component is NeverOverwrite and
// Permanent, so upgrades and uninstall keep the operator's configuration.
var wxsTemplate = template.Must(template.New("agent.wxs").Parse(`<?xml version="1.0" encoding="utf-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="ServiceRadar Agent" Manufacturer="Carver Automation" Version="{{.MSIVersion}}" UpgradeCode="{{.UpgradeCode}}" Scope="perMachine">
    <MajorUpgrade AllowSameVersionUpgrades="yes" DowngradeErrorMessage="A newer version of [ProductName] is already installed." />
    <MediaTemplate EmbedCab="yes" />
    <Feature Id="Main">
      <ComponentGroupRef Id="AgentComponents" />
    </Feature>
  </Package>

  <Fragment>
    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="INSTALLFOLDER" Name="ServiceRadar" />
    </StandardDirectory>
    <StandardDirectory Id="CommonAppDataFolder">
      <Directory Id="DATAFOLDER" Name="ServiceRadar">
        <Directory Id="CONFIGFOLDER" Name="config" />
      </Directory>
    </StandardDirectory>
  </Fragment>

  <Fragment>
    <ComponentGroup Id="AgentComponents">
      <Component Directory="INSTALLFOLDER">
        <File Id="AgentExe" Source="{{.AgentPath}}" Name="serviceradar-agent.exe" KeyPath="yes" />
        <ServiceInstall Name="` + serviceName + `" DisplayName="ServiceRadar Agent" Description="Collects monitoring data and pushes it to the ServiceRadar gateway." Type="ownProcess" Start="auto" ErrorControl="normal" Account="LocalSystem" Arguments="--config &quot;[CONFIGFOLDER]agent.json&quot;">
          <ServiceConfigFailureActions OnInstall="yes" OnReinstall="yes" ResetPeriod="86400">
            <Failure Action="restartService" Delay="10000" />
            <Failure Action="restartService" Delay="30000" />
            <Failure Action="restartService" Delay="60000" />
          </ServiceConfigFailureActions>
        </ServiceInstall>
        <ServiceControl Name="` + serviceName + `" Stop="both" Remove="uninstall" Wait="yes" />
      </Component>
      <Component Directory="CONFIGFOLDER" NeverOverwrite="yes" Permanent="yes">
        <File Id="AgentConfig" Source="{{.ConfigPath}}" Name="agent.json" KeyPath="yes" />
      </Component>
    </ComponentGroup>
  </Fragment>
</Wix>
`))

func renderWXS(v wxsValues) ([]byte, error) {
	for _, value := range []string{v.MSIVersion, v.UpgradeCode, v.AgentPath, v.ConfigPath} {
		if value == "" || strings.ContainsAny(value, "\"&<>'\r\n") {
			return nil, fmt.Errorf("%w: WiX template value %q is empty or needs escaping", errInvalidPackage, value)
		}
	}

	var buf bytes.Buffer
	if err := wxsTemplate.Execute(&buf, v); err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}
