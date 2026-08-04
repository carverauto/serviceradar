package fetch

import (
	"fmt"
	"net/url"
	"path"
	"regexp"
)

func ParseGithubImportArg(imp string) (name, version, owner, repo, ref string, err error) {
	r := regexp.MustCompile(`(?P<Name>[^@=]*)@?(?P<Version>[^=]*)=?github\.com/(?P<Owner>[^/]+)/(?P<Repo>[^@]+)@?(?P<Ref>.*)`)
	match := r.FindStringSubmatch(imp)
	if len(match) == 6 {
		name = match[1]
		version = match[2]
		owner = match[3]
		repo = match[4]
		ref = match[5]
		if ref == "" {
			ref = "main"
		}
	} else {
		err = fmt.Errorf("not a valid import string: %s", imp)
	}
	return
}

func DownloadRef(owner, repo, ref, filepath string) error {
	url := url.URL{
		Scheme: "https",
		Host:   "github.com",
		Path:   path.Join(owner, repo, "archive", ref+".tar.gz"),
	}

	return Download(&url, filepath)
}
