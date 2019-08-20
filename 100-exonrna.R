################################################################
## exon
my_exon = read_tsv('Data/TCGA.PANCAN.sampleMap__HiSeqV2_exon.gz',
    trim_ws = TRUE, n_max = my.limit )
################################################################
## we need to load exon data one chromosome at a time
## it's BIG

my_exon$chr = gsub(':.*', '', my_exon$Sample)

################################################################
## we are going to create and destroy database connections every chromosome
## will this allow mysql to manage tmp spaces better?
################################################################

plyr::d_ply( my_exon, ~ chr, function(x) {
    if(FALSE){
        if(mysql) {
            if( mysqldb == 'dev') {
                con = RMySQL::dbConnect (
                    drv       = RMySQL::MySQL(),
                    dbname    = "pancan2018dev",
                    host      = "pancan2018dev.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
                    port      = 3306,
                    username  = "admin",
                    password  = "Adminuser19")
            } else {
                contmp = RMySQL::dbConnect (
                    drv       = RMySQL::MySQL(),
                    dbname    = "pancan2018",
                    host      = "pancan2018.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
                    port      = 3306,
                    username  = "admin",
                    password  = "Adminuser19")
            }
        } else {
            contmp = con
        }
    }
    gc()
    print(x$chr[[1]])
    x = x %>%
        rename(id = Sample) %>%
            left_join( my_geoexon %>% select (probe, id) ) %>%
                select( -id, -chr ) %>% 
                    gather( sample, value, -probe ) %>%
                        drop_na() %>% 
                            mutate(type = 'exon') %>%
                                select( sample, probe, value, type )
    print(head(x))
    print(dim(x))
    if(nrow(x) > 0) {
        tablemaker(x, suffix = FALSE, deleteType = FALSE, connection = con)
    }
    if(FALSE){
        if( mysql ) {
            dbDisconnect(contmp)
        }
    }
})

my_exon = NULL; gc()
