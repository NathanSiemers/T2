package main

import "testing"

func TestEnsureHemePreset(t *testing.T) {
	heme := []string{"Acute Myeloid Leukemia", "Whole Blood", "Not A Cohort"}
	fresh := func() *Dataset {
		d := &Dataset{levels: map[string][]string{
			"cohort":      {"Acute Myeloid Leukemia", "Whole Blood", "Breast Invasive Carcinoma"},
			"sample_type": {"Primary Tumor", "Normal Tissue"},
		}}
		d.Roles.HemeValues = heme
		return d
	}

	// a table without a heme exclusion (Toil) gets the derived one, with the known values only
	d := fresh()
	d.presets = []Preset{{Label: "GTEx normal tissues", Source: "database", Rules: []PresetRule{{Column: "study", Op: "in", Values: []string{"GTEX"}}}}}
	d.ensureHemePreset()
	if len(d.presets) != 2 || d.presets[1].Label != "Exclude tumors of heme origin" || d.presets[1].Source != "derived" {
		t.Fatalf("heme preset not added: %+v", d.presets)
	}
	r := d.presets[1].Rules[0]
	if r.Column != "cohort" || r.Op != "not in" || len(r.Values) != 2 {
		t.Errorf("unexpected heme rule: %+v", r)
	}

	// a table that already drops cohorts (TCGA) is left alone
	d = fresh()
	d.presets = []Preset{{Label: "Exclude tumors of heme origin", Source: "database", Rules: []PresetRule{{Column: "cohort", Op: "not in", Values: []string{"LAML"}}}}}
	d.ensureHemePreset()
	if len(d.presets) != 1 {
		t.Errorf("heme preset duplicated: %+v", d.presets)
	}

	// no cohort column, or no heme value among its levels: nothing is added
	d = fresh()
	delete(d.levels, "cohort")
	d.ensureHemePreset()
	if len(d.presets) != 0 {
		t.Errorf("preset added without a cohort column: %+v", d.presets)
	}
	d = fresh()
	d.Roles.HemeValues = []string{"Not A Cohort"}
	d.ensureHemePreset()
	if len(d.presets) != 0 {
		t.Errorf("preset added without any known heme value: %+v", d.presets)
	}
}
