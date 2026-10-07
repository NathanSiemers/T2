package main

// What each clinical column means: the words behind the names (TCGA-CDR fields, the
// Pan-Cancer Atlas subtypes, the Toil phenotype file). They live in a tab-separated
// file next to this source and are served in a dataset's /meta as "clinical_descriptions",
// for the columns that dataset has. Keep the file as the one place these words are written.

import (
	_ "embed"
	"strings"
)

//go:embed clinical_descriptions.tsv
var clinicalDescriptionsTSV string

type clinicalDescription struct {
	Column      string `json:"column"`
	Description string `json:"description"`
	Source      string `json:"source,omitempty"`
}

// clinicalDescriptions returns the descriptions that apply to dataset `name`, in the order
// of `columns` (the dataset's clinical columns); columns without a description are left out.
func clinicalDescriptions(name string, columns []string) []clinicalDescription {
	byColumn := map[string]clinicalDescription{}
	for i, line := range strings.Split(clinicalDescriptionsTSV, "\n") {
		if i == 0 || strings.TrimSpace(line) == "" {
			continue // the header, blank lines
		}
		f := strings.Split(line, "\t")
		if len(f) < 3 {
			continue
		}
		applies := false
		for _, ds := range strings.Split(f[1], ",") {
			ds = strings.TrimSpace(ds)
			if ds == "*" || strings.EqualFold(ds, name) {
				applies = true
			}
		}
		if !applies {
			continue
		}
		// a dataset-specific line wins over a "*" line for the same column
		if prev, ok := byColumn[f[0]]; ok && prev.Source != "" && f[1] == "*" {
			continue
		}
		cd := clinicalDescription{Column: f[0], Description: f[2]}
		if len(f) > 3 {
			cd.Source = f[3]
		}
		byColumn[f[0]] = cd
	}
	out := []clinicalDescription{}
	for _, c := range columns {
		if cd, ok := byColumn[c]; ok {
			out = append(out, cd)
		}
	}
	return out
}
