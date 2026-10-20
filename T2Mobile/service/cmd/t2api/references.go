package main

import (
	"encoding/json"
	"log"
	"regexp"
	"strings"
)

// Reference: one record of the dataset's bibliography (dataset_meta key `references`).
// URL is computed: PubMed when there is a pmid, else doi.org, else the url given in the data.
type Reference struct {
	Group   string `json:"group"`
	Title   string `json:"title"`
	Authors string `json:"authors"`
	Journal string `json:"journal"`
	Year    int    `json:"year"`
	PMID    string `json:"pmid"`
	DOI     string `json:"doi"`
	URL     string `json:"url"`
	Note    string `json:"note"`
}

func pubmedURL(pmid string) string { return "https://pubmed.ncbi.nlm.nih.gov/" + pmid + "/" }
func doiURL(doi string) string     { return "https://doi.org/" + doi }

// loadReferences parses dataset_meta `references`. A malformed value gives an empty list;
// a record without a title is dropped (logged); everything else is kept in input order.
func (d *Dataset) loadReferences() error {
	d.references = []Reference{}
	raw := strings.TrimSpace(d.meta["references"])
	if raw == "" {
		return nil
	}
	var decl []Reference
	if err := json.Unmarshal([]byte(raw), &decl); err != nil {
		log.Printf("%s: dataset_meta references is not a JSON array of records (%v): none offered", d.Name, err)
		return nil
	}
	for i, r := range decl {
		r.Title = strings.TrimSpace(r.Title)
		if r.Title == "" {
			log.Printf("%s: reference #%d dropped: no title", d.Name, i+1)
			continue
		}
		r.PMID, r.DOI = strings.TrimSpace(r.PMID), strings.TrimSpace(r.DOI)
		switch {
		case r.PMID != "":
			r.URL = pubmedURL(r.PMID)
		case r.DOI != "":
			r.URL = doiURL(r.DOI)
		}
		if r.Journal == "" || r.Authors == "" {
			log.Printf("%s: reference %q has no journal or no authors", d.Name, r.Title)
		}
		d.references = append(d.references, r)
	}
	return nil
}

var (
	pmidRe = regexp.MustCompile(`PMID:?\s*(\d+)`)
	doiRe  = regexp.MustCompile(`10\.\d{4,9}/\S+`)
)

// joinReference adds reference_* fields to a types row from its `reference` text.
func (d *Dataset) joinReference(row map[string]any) {
	text, _ := row["reference"].(string)
	if text == "" {
		return
	}
	pmid, doi := "", ""
	if m := pmidRe.FindStringSubmatch(text); m != nil {
		pmid = m[1]
	} else if m := doiRe.FindString(text); m != "" {
		doi = strings.TrimRight(m, ".),;")
	}
	if pmid == "" && doi == "" {
		return
	}
	for _, r := range d.references {
		if (pmid != "" && r.PMID == pmid) || (doi != "" && strings.EqualFold(r.DOI, doi)) {
			row["reference_title"], row["reference_authors"] = r.Title, r.Authors
			row["reference_journal"], row["reference_year"], row["reference_url"] = r.Journal, r.Year, r.URL
			return
		}
	}
	if pmid != "" {
		row["reference_url"] = pubmedURL(pmid)
	} else {
		row["reference_url"] = doiURL(doi)
	}
}
