# Database Performance Report

**Date:** 2026-04-13 19:19:55
**Database:** tcga.db (36.2 GB)
**Iterations:** 6 per test

## distinct_probe_lookup

| Detail | Probes | Median (s) | Min (s) | Max (s) | Rows |
|--------|-------:|-----------:|--------:|--------:|-----:|
| 10 probes | 10 | 0.047 | 0.046 | 0.047 | 10 |
| 100 probes | 100 | 0.454 | 0.453 | 0.456 | 100 |
| 300 probes | 300 | 1.362 | 1.358 | 1.377 | 300 |

## mixed_num_cat

| Detail | Probes | Median (s) | Min (s) | Max (s) | Rows |
|--------|-------:|-----------:|--------:|--------:|-----:|
| CD8A+FOXP3+TP53.mut | 3 | 0.178 | 0.178 | 0.181 | 31,242 |
| CD8A+FOXP3+TP53.mut+KRAS.cnc+cohort+sample_type | 6 | 0.224 | 0.219 | 0.225 | 42,087 |

## tcgacats_by_type

| Detail | Probes | Median (s) | Min (s) | Max (s) | Rows |
|--------|-------:|-----------:|--------:|--------:|-----:|
| immune_subtype | 1 | 0.264 | 0.263 | 0.267 | 9,126 |
| molec_subtype | 8 | 0.310 | 0.307 | 0.327 | 61,872 |

## tcgacats_probe_count

| Detail | Probes | Median (s) | Min (s) | Max (s) | Rows |
|--------|-------:|-----------:|--------:|--------:|-----:|
| 1 cat probes | 1 | 0.001 | 0.001 | 0.006 | 1,057 |
| 3 cat probes | 3 | 0.002 | 0.001 | 0.003 | 412 |
| 10 cat probes | 10 | 0.006 | 0.004 | 0.012 | 1,384 |
| 30 cat probes | 30 | 0.020 | 0.016 | 0.021 | 4,134 |

## tcgas_by_type

| Detail | Probes | Median (s) | Min (s) | Max (s) | Rows |
|--------|-------:|-----------:|--------:|--------:|-----:|
| msi | 1 | 0.025 | 0.024 | 0.025 | 10,793 |
| tmb | 1 | 0.026 | 0.025 | 0.026 | 9,104 |
| estimate | 3 | 0.089 | 0.088 | 0.091 | 33,207 |
| hrd | 4 | 0.107 | 0.106 | 0.110 | 42,588 |
| sig | 45 | 1.539 | 1.475 | 1.588 | 576,180 |
| immune_score | 68 | 3.126 | 3.102 | 3.150 | 737,936 |
| rabit | 150 | 1.869 | 1.858 | 1.895 | 777,000 |
| rppa | 258 | 10.743 | 10.616 | 10.823 | 2,000,532 |

## tcgas_probe_count

| Detail | Probes | Median (s) | Min (s) | Max (s) | Rows |
|--------|-------:|-----------:|--------:|--------:|-----:|
| 1 rna probes | 1 | 0.076 | 0.048 | 0.077 | 11,069 |
| 3 rna probes | 3 | 0.209 | 0.182 | 0.229 | 33,207 |
| 10 rna probes | 10 | 0.689 | 0.565 | 0.740 | 110,690 |
| 30 rna probes | 30 | 2.120 | 1.957 | 2.337 | 332,070 |
| 100 rna probes | 100 | 6.984 | 6.829 | 7.184 | 1,106,900 |
| 300 rna probes | 300 | 20.734 | 20.451 | 21.247 | 3,320,700 |

