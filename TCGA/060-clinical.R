###############################################################
## create and also populate table 'clin' here

my_clin = read_tsv('Data/Survival_SupplementalTable_S1_20171025_xena_sp.gz',
    col_types = cols(
        .default = col_character(),
        age_at_initial_pathologic_diagnosis = col_double(),
        clinical_stage = col_character(),
        initial_pathologic_dx_year = col_double(),
        birth_days_to = col_double(),
        last_contact_days_to = col_double(),
        death_days_to = col_double(),
        cause_of_death = col_character(),
        new_tumor_event_dx_days_to = col_double(),
        residual_tumor = col_character(),
        OS = col_double(),
        OS.time = col_double(),
        DSS = col_double(),
        DSS.time = col_double(),
        DFI = col_double(),
        DFI.time = col_double(),
        PFI = col_double(),
        PFI.time = col_double()
        ),
    trim_ws = TRUE)
##  , n_max = my.limit )  
my_clin = my_clin %>% rename(Patient = '_PATIENT',
    tumtype = "cancer type abbreviation"  )
################################################################
## phenos table is small, add to clin before joining
my_pheno = read_tsv('Data/TCGA_phenotype_denseDataOnlyDownload.tsv.gz',
    trim_ws = TRUE, n_max = my.limit ) %>% rename ( cohort = "_primary_disease" )
my_pheno
dim(my_clin)
dim(my_pheno)
### oops my_pheno is bigger
which(! my_pheno$sample %in% my_clin$sample )
which(! my_clin$sample %in% my_pheno$sample )
my_clin = my_pheno %>% left_join(my_clin, b = 'sample')
dim(my_clin)
my_clin


try(dbRemoveTable(con, 'clin'), silent = TRUE)
dbWriteTable(con, 'clin', my_clin, row.names = FALSE)
str( dbGetQuery(con,  'select * from clin') )

my_clin = NULL; gc()

