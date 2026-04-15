# Database Schema (ERD)

Generated: 2026-04-15 03:33:49.314464

```mermaid
erDiagram
    allprobes {
        string key
        string probe
    }
    clin {
        string sample
        string sample_type_id
        string sample_type
        string cohort
        string Patient
        string tumtype
        string age_at_initial_pathologic_diagnosis
        string gender
        string race
        string ajcc_pathologic_tumor_stage
        string _plus_27_more_columns
    }
    clinpheno {
        string sample
        string sample_type_id
        string sample_type
        string cohort
        string Patient
        string tumtype
        string age_at_initial_pathologic_diagnosis
        string gender
        string race
        string ajcc_pathologic_tumor_stage
        string _plus_45_more_columns
    }
    cnv {
        string sampleID
        string chr
        string start
        string end
        string value
    }
    cohorts {
        string cohort
        string lcohort
        string cohortstring
    }
    datatypes {
        string type
        string r_datatype
    }
    geo {
        string id
        string gene
        string chrom
        string chromStart
        string chromEnd
        string strand
        string thickStart
        string thickEnd
        string blockCount
        string blockSizes
        string _plus_1_more_columns
    }
    mutation {
        string sample
        string chr
        string start
        string end
        string reference
        string alt
        string gene
        string effect
        string Amino_Acid_Change
        string DNA_VAF
        string _plus_4_more_columns
    }
    mutationsamples {
        string sample
    }
    nosuffix {
        string type
    }
    probe_types {
        string probekey
        string type
    }
    probes {
        string key
        string probe
    }
    samples {
        string key
        string sample
    }
    tcgacati {
        string samplekey
        string probekey
        string value
        string type
    }
    tcgai {
        string samplekey
        string probekey
        string value
        string type
    }
    tested {
        string sample
        string value
        string type
    }
    types {
        string key
        string type
    }
    tcga {
        string sample
        string sample_type_id
        string sample_type
        string cohort
        string Patient
        string tumtype
        string age_at_initial_pathologic_diagnosis
        string gender
        string race
        string ajcc_pathologic_tumor_stage
        string _plus_48_more_columns
    }
    tcgacat {
        string sample
        string sample_type_id
        string sample_type
        string cohort
        string Patient
        string tumtype
        string age_at_initial_pathologic_diagnosis
        string gender
        string race
        string ajcc_pathologic_tumor_stage
        string _plus_48_more_columns
    }
    tcgacats {
        string sample
        string probe
        string value
        string type
    }
    tcgas {
        string sample
        string probe
        string value
        string type
    }

    %% Core data relationships
    samples ||--o{ tcgai : samplekey
    probes ||--o{ tcgai : probekey
    samples ||--o{ tcgacati : samplekey
    probes ||--o{ tcgacati : probekey
    types ||--o{ tcgai : type
    types ||--o{ tcgacati : type

    %% Lookup tables
    probes ||--o{ probe_types : probekey
    probes ||--o{ allprobes : probe
    types ||--o{ datatypes : type
    types ||--o{ nosuffix : type
    types ||--o{ tested : type

    %% Clinical
    clin ||--|| clinpheno : sample
    clinpheno ||--o{ cohorts : tumtype

    %% Views (dense numeric)
    probe_types }o--|| tcgas : "probekey+type"
    tested }o--|| tcgas : "type+sample"
    tcgai }o--|| tcgas : "probekey+type+samplekey"
    clinpheno ||--o{ tcga : sample
    tcgas }o--|| tcga : "sample+probe"

    %% Views (simple categorical)
    tcgacati }o--|| tcgacats : "samplekey+probekey"
    clinpheno ||--o{ tcgacat : sample
    tcgacati }o--|| tcgacat : "samplekey+probekey"

    %% Mutation-specific
    mutation ||--o{ mutationsamples : sample
    cnv ||--o{ geo : gene
```

## Indexes

| Table | Index | Columns |
|-------|-------|---------|
| clinpheno | clinphenoidx | sample |
| mutation | mutidx | gene |
| mutationsamples | mutationsamplesidx | sample |
| probe_types | probe_types_pk | probekey, type |
| probe_types | probe_types_tp | type, probekey |
| probes | probesidx |  probe  |
| samples | samplesidx |  sample  |
| tcgacati | tcgacatiidx_pts | probekey, type, samplekey |
| tcgai | typeidx |  type  |
| tcgai | tcgaiidx_pts | probekey, type, samplekey |
| tested | tested_type | type |
| tested | tested_type_sample | type, sample |

## Table Sizes

| Table | Type | Rows | Columns |
|-------|------|-----:|--------:|
| allprobes | table | 135,640 | 2 |
| clin | table | 12,804 | 37 |
| clinpheno | table | 12,804 | 55 |
| cnv | table | 1,790,483 | 5 |
| cohorts | table | 33 | 3 |
| datatypes | table | 19 | 2 |
| geo | table | 43,254 | 11 |
| mutation | table | 2,907,335 | 14 |
| mutationsamples | table | 9,104 | 1 |
| nosuffix | table | 3 | 1 |
| probe_types | table | 91,175 | 2 |
| probes | table | 135,603 | 2 |
| samples | table | 13,054 | 2 |
| tcgacati | table | 2,978,333 | 4 |
| tcgai | table | 577,415,719 | 4 |
| tested | table | 188,044 | 3 |
| types | table | 19 | 2 |
| tcga | view | (view) | 58 |
| tcgacat | view | (view) | 58 |
| tcgacats | view | (view) | 4 |
| tcgas | view | (view) | 4 |

