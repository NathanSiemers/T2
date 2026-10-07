
## The GDC viral-read table (per-sample normalised read counts of CMV, EBV, HBV, HCV, HPV,
## ...). Kept in Data/ like every other input, so that a no-download rebuild does not depend
## on the network: a connection reset here ended the build of 2026-10-07 after 54 minutes.
## Fetched once (or again when the master script runs with download = TRUE).
viral_url  = 'https://api.gdc.cancer.gov/data/a55229b3-da03-49fc-a310-9b1bf16b8512'
viral_file = 'Data/viral_reads_gdc_a55229b3.tsv'
if (!file.exists(viral_file) || isTRUE(download)) {
    message('135-viral: downloading ', viral_url, ' -> ', viral_file)
    download.file(viral_url, viral_file, mode = 'wb', quiet = TRUE)
}
my_viral = read_tsv(viral_file,
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(sample = SampleBarcode) %>%
            mutate( sample = gsub('[A-Z]$', '', sample ) ) %>%
                    select( -AliquotBarcode, -ParticipantBarcode, -Study, -SampleTypeLetterCode ) %>%
                gather( probe, value, -sample ) %>%
                average_duplicate_rows('viral') %>%   ## several aliquots of one sample: mean of the counts
                    mutate( type = 'viral' ) %>%
                        mutate( value = log2( value + 1 ) ) %>%
                        select( sample, probe, value, type ) 

my_viral

tablemaker(my_viral)

my_viral = NULL; gc()
