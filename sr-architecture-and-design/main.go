package main

import (
	"fmt"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
	"text/template"
	"time"

	"gitlab.com/golang-commonmark/markdown"
)

type ADRMeta struct {
	Index   int
	Authors []string
	Date    time.Time
	Status  string
	Tags    []string
	Path    string
}

type ADR struct {
	Heading string
	Meta    ADRMeta
}

var (
	validStatus = []string{"Approved", "Partially Implemented", "Implemented", "Deprecated"}
)

func parseCommaList(l string) []string {
	tags := strings.Split(l, ",")
	res := []string{}
	for _, t := range tags {
		res = append(res, strings.TrimSpace(t))
	}
	return res
}

func parseADR(adrPath string) (*ADR, error) {
	body, err := os.ReadFile(adrPath)
	if err != nil {
		panic(err)
	}

	md := markdown.New()
	tokens := md.Parse(body)

	in1stHdr := false
	in1stTbl := false
	curHdrKey := ""

	adr := ADR{
		Meta: ADRMeta{
			Path: adrPath,
		},
	}

	base := strings.TrimSuffix(path.Base(adrPath), path.Ext(adrPath))
	parts := strings.Split(base, "-")
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid filename %s in %s", base, adrPath)
	}

	idx, err := strconv.Atoi(parts[1])
	if err != nil {
		return nil, fmt.Errorf("invalid file sequence %s in %s", parts[1], adrPath)
	}

	adr.Meta.Index = idx

	for _, t := range tokens {
		switch tok := t.(type) {
		case *markdown.Inline:
			switch {
			case in1stHdr:
				adr.Heading = tok.Content

			case curHdrKey == "Date":
				t, err := time.Parse("2006-01-02", tok.Content)
				if err != nil {
					return nil, fmt.Errorf("invalid date format, not YYYY-MM-DD: %s", err)
				}

				adr.Meta.Date = t
			case curHdrKey == "Author":
				adr.Meta.Authors = parseCommaList(tok.Content)

			case curHdrKey == "Status":
				adr.Meta.Status = tok.Content

			case curHdrKey == "Tags":
				adr.Meta.Tags = parseCommaList(tok.Content)

			case in1stTbl:
				curHdrKey = tok.Content
			}

		case *markdown.TbodyOpen:
			in1stTbl = true

		case *markdown.HeadingOpen:
			if adr.Heading == "" {
				in1stHdr = true
			}

		case *markdown.TbodyClose:
			in1stTbl = false

			// stop parsing after first table
			break
		case *markdown.HeadingClose:
			in1stHdr = false
		case *markdown.TableClose:
			in1stTbl = false
		case *markdown.TrClose:
			curHdrKey = ""
		}
	}

	if adr.Meta.Index == 0 {
		return nil, fmt.Errorf("invalid ADR Index in %s", adr.Meta.Path)
	}
	if adr.Meta.Date.IsZero() {
		return nil, fmt.Errorf("date is required in %s", adr.Meta.Path)
	}
	if !isValidStatus(adr.Meta.Status) {
		return nil, fmt.Errorf("invalid status %q, must be one of: %s in %s", adr.Meta.Status, strings.Join(validStatus, ", "), adr.Meta.Path)
	}
	if len(adr.Meta.Authors) == 0 {
		return nil, fmt.Errorf("authors is required in %s", adr.Meta.Path)
	}
	if len(adr.Meta.Tags) == 0 {
		return nil, fmt.Errorf("tags is required in %s", adr.Meta.Path)
	}

	return &adr, nil
}

func isValidStatus(status string) bool {
	for _, s := range validStatus {
		if status == s {
			return true
		}
	}

	return false
}

func verifyUniqueIndexes(adrs []*ADR) error {
	indexes := map[int]string{}
	for _, a := range adrs {
		path, ok := indexes[a.Meta.Index]
		if ok {
			return fmt.Errorf("duplicate index %d, conflict between %s and %s", a.Meta.Index, a.Meta.Path, path)
		}
		indexes[a.Meta.Index] = a.Meta.Path
	}

	return nil
}

func renderIndexes(adrs []*ADR) error {
	tags := map[string]int{}
	for _, adr := range adrs {
		for _, tag := range adr.Meta.Tags {
			tags[tag] = 1
		}
	}

	tagsList := []string{}
	hasDeprecated := false
	for k := range tags {
		if k == "deprecated" {
			hasDeprecated = true
			continue
		}
		tagsList = append(tagsList, k)
	}
	sort.Strings(tagsList)
	if hasDeprecated {
		tagsList = append(tagsList, "deprecated")
	}

	type tagAdrs struct {
		Tag  string
		Adrs []*ADR
	}

	renderList := []tagAdrs{}

	for _, tag := range tagsList {
		matched := []*ADR{}
		for _, adr := range adrs {
			for _, mt := range adr.Meta.Tags {
				if tag == mt {
					matched = append(matched, adr)
				}
			}
		}

		sort.Slice(matched, func(i, j int) bool {
			return matched[i].Meta.Index < matched[j].Meta.Index
		})

		renderList = append(renderList, tagAdrs{Tag: tag, Adrs: matched})
	}

	funcMap := template.FuncMap{
		"join": func(i []string) string {
			return strings.Join(i, ", ")
		},
		"title": func(i string) string {
			return strings.Title(i)
		},
	}

	readme, err := template.New(".readme.templ").Funcs(funcMap).ParseFiles(".readme.templ")
	if err != nil {
		return err
	}
	err = readme.Execute(os.Stdout, renderList)
	if err != nil {
		return err
	}
	return nil
}

func main() {
	dir, err := os.ReadDir("adr")
	if err != nil {
		panic(err)
	}

	adrs := []*ADR{}

	for _, mdf := range dir {
		if mdf.IsDir() {
			continue
		}

		if path.Ext(mdf.Name()) != ".md" {
			continue
		}

		adr, err := parseADR(path.Join("adr", mdf.Name()))
		if err != nil {
			panic(err)
		}

		adrs = append(adrs, adr)
	}

	err = verifyUniqueIndexes(adrs)
	if err != nil {
		panic(err)
	}

	err = renderIndexes(adrs)
	if err != nil {
		panic(err)
	}
}
