package fetch

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"path"
	"regexp"
)

func ParseHexImportArg(imp string) (name, pkg, version string, err error) {
	r := regexp.MustCompile(`(?P<Name>[^=]*)=?hex\.pm/(?P<Pkg>[^@]+)@?(?P<Version>.*)`)
	match := r.FindStringSubmatch(imp)
	if len(match) == 4 {
		name = match[1]
		pkg = match[2]
		version = match[3]
		if version == "" {
			version = "latest"
		}
	} else {
		err = fmt.Errorf("not a valid import string: %s", imp)
	}
	return
}

type HexPmRequirement struct {
	App         string `json:"app"`
	Optional    bool   `json:"optional"`
	Requirement string `json:"requirement"`
}

type HexPmRelease struct {
	Requirements map[string]HexPmRequirement `json:"requirements"`
}

type HexPmReleases struct {
	LatestStableVersion string `json:"latest_stable_version"`
	LatestVersion       string `json:"latest_version"`
}

func hexPmApiUrl(elem ...string) *url.URL {
	return &url.URL{
		Scheme: "https",
		Host:   "hex.pm",
		Path:   path.Join("api", path.Join(elem...)),
	}
}

func GetRelease(pkg, version string) (*HexPmRelease, error) {
	url := hexPmApiUrl("packages", pkg, "releases", version)
	resp, err := http.Get(url.String())
	if err != nil {
		return nil, err
	}

	defer resp.Body.Close()
	var release HexPmRelease
	err = json.NewDecoder(resp.Body).Decode(&release)
	if err != nil {
		return nil, err
	}
	return &release, nil
}

func LatestRelease(pkg string) (string, error) {
	url := hexPmApiUrl("packages", pkg)
	resp, err := http.Get(url.String())
	if err != nil {
		return "", err
	}

	defer resp.Body.Close()
	var releases HexPmReleases
	err = json.NewDecoder(resp.Body).Decode(&releases)
	if err != nil {
		return "", err
	}
	return releases.LatestStableVersion, nil
}

func DownloadRelease(pkg, version, filepath string) error {
	url := url.URL{
		Scheme: "https",
		Host:   "repo.hex.pm",
		Path:   path.Join("tarballs", pkg+"-"+version+".tar"),
	}

	return Download(&url, filepath)
}
