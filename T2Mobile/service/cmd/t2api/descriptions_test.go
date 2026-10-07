package main

import "testing"

func TestClinicalDescriptions(t *testing.T) {
	tcga := clinicalDescriptions("TCGA", []string{"sample_type", "OS", "OS.time", "Subtype_Selected", "no_such_column", "study"})
	if len(tcga) != 4 {
		t.Fatalf("TCGA: want 4 descriptions, got %d: %+v", len(tcga), tcga)
	}
	if tcga[0].Column != "sample_type" || tcga[1].Column != "OS" || tcga[3].Column != "Subtype_Selected" {
		t.Errorf("TCGA: order not kept: %+v", tcga)
	}
	for _, d := range tcga {
		if len(d.Description) < 20 {
			t.Errorf("%s: description too short: %q", d.Column, d.Description)
		}
	}
	toil := clinicalDescriptions("tcgatargetgtex", []string{"study", "disease", "subtype", "cohort", "OS"})
	if len(toil) != 4 {
		t.Fatalf("Toil: want 4 descriptions, got %d: %+v", len(toil), toil)
	}
	if toil[2].Column != "subtype" || toil[2].Description[:19] != "In this collection " {
		t.Errorf("Toil: the dataset-specific subtype line did not win: %+v", toil[2])
	}
	// every line of the file is well formed
	all := clinicalDescriptions("TCGA", nil)
	if len(all) != 0 {
		t.Errorf("no columns asked for, got %d", len(all))
	}
}
