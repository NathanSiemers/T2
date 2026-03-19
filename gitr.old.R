library(DBI)
library(dplyr)
if(!require('furrr')) install.packages('furrr')
if(!require('future')) install.packages('future')
future::plan('multisession', workers = 6)
gitrdb = 'tcga.db'


## gitr - data retriever function
gitr = function(probes, phenos = TRUE, nonormal = FALSE, noheme = FALSE,
                cohort = 'all', conn = con,
                makefactors = TRUE,
                dbfile = gitrdb,
                db = 'tcga',
                dbcat = 'tcgacat') {
  ##print(match.call())
  if(FALSE){ #testing
    probes = c('CD8A', 'CD8B'); phenos = TRUE; nonormal = FALSE; cohort = 'all'; makefactors = TRUE; dbfile = gitrdb
  }
  gitrconn = RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile, flags = RSQLite::SQLITE_RO )
  cohorts = tbl(gitrconn, 'cohorts')
  tcgas = tbl(gitrconn, 'tcgas')
  tcgacats = tbl(gitrconn, 'tcgacats')
  clin = tbl(gitrconn, 'clin')
  clinpheno = tbl(gitrconn, 'clinpheno')
  clinheader = clin %>% select(sample) %>% collect()
  tested = tbl(gitrconn, 'tested')
  tested_c = collect(tested)
  ##allprobes = tbl(gitrconn, 'allprobes')
  
  ## new core retrieval
  ## hope it's not slow
  ## will by default set missing but tested values to 0
  ## not tested will be NA
  ##probes = c("FOXP3", "TP53.mut")
  
  ###pout = map( unique(probes), function(x){
  
  pout = furrr::future_map( unique(probes), function(x){
    ## Database connection and handles
    f_gitrconn = RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile, flags = RSQLite::SQLITE_RO )
    cohorts = tbl(f_gitrconn, 'cohorts')
    tcgas = tbl(f_gitrconn, 'tcgas')
    tcgacats = tbl(f_gitrconn, 'tcgacats')
    clin = tbl(f_gitrconn, 'clin')
    clinpheno = tbl(f_gitrconn, 'clinpheno')
    clinpheno = collect(clinpheno)
    allprobes = tbl(f_gitrconn, 'allprobes')
    ##
    tcgaout = data.frame()
    if(x %in% colnames(clinpheno)) {
      tcgaout = clinpheno[, c('sample', x), drop = FALSE]
      print(head(tcgaout))
      return(tcgaout)
    } else {
      if (tcgas %>% filter( probe == x) %>% head(1) %>% collect %>% nrow == 1 ) {
        tcgaout = tcgas %>%
          filter( probe == x) %>%
          distinct( sample, probe, type, .keep_all = TRUE ) %>%
          collect()
      } else {
        if (tcgacats %>% filter( probe == x) %>% head(1) %>% collect %>% nrow == 1 ) {
          tcgaout = tcgacats %>%
            filter( probe == x) %>%
            distinct( sample, probe, type, .keep_all = TRUE )  %>%
            collect()
        }
      }}
    if(nrow(tcgaout) == 0) return(collect(clinpheno)[, c('sample'), drop = FALSE])
    thistype = head(tcgaout,1) %>% pull(type)
    mytested =  tested_c %>% mutate( probe = x ) %>% filter(value == 1 & type == thistype) %>%
      filter(! sample %in% tcgaout$sample ) %>% distinct(sample, .keep_all = TRUE) %>% 
      mutate(value = 0)
    out = rbind(tcgaout, mytested) %>% tidyr::spread(probe, value) %>% select(-type) 
    out = left_join( clinheader, out, by = join_by(sample), multiple = "any")
    dbDisconnect(f_gitrconn)
    return(out)
  })
  rout = purrr::reduce(pout[!is.null(pout)], left_join, by = join_by(sample))
  if(phenos){
    out = collect(clinpheno) %>% 
      mutate(subtype = Subtype_Selected, lcohort = cohort, cohort = tumtype) %>%
      left_join(rout[, c('sample', colnames(rout)[! colnames(rout) %in% colnames(clinpheno) ] ) ], by = join_by(sample) )
  } else {
    out = rout
  }
  ## final specialized filters and factors for TCGA
  if( nonormal )  {
    out = out %>% dplyr::filter( sample_type != "Solid Tissue Normal" )
  }
  if( noheme ) {
    out = out %>% dplyr::filter( tumtype != "LAML" & tumtype != "THYM" & tumtype != "DLBC")
  }
  ## include only selected cohorts if desired
  if( !is.null(cohort) ) {
    if ( any (cohort  != "all" )  ) {
      out = out[ out$cohort %in% cohort, ]
    }
  }
  ## set factor levels for sample_type
  if(phenos) {
    print("setting sample type factors")
    print(head(colnames(out)))
    print(summary(out$sample_type))
  out$sample_type = factor(out$sample_type,
                           levels = c( "Primary Tumor",
                                       "Recurrent Tumor",
                                       "Metastatic",
                                       "Additional - New Primary",
                                       "Additional Metastatic",
                                       "Primary Blood Derived Cancer - Peripheral Blood",
                                       "Solid Tissue Normal"
                           ) )
  }
  ## make factors
  if( makefactors ) {
    out = out %>% mutate_if(is.character, as.factor)
    out = out %>% mutate_at( dplyr::vars( ends_with('mut') ) , ~ as.factor(.) )
    out = out %>% mutate_at( dplyr::vars( ends_with('cnc') ) , ~ as.factor(.) )
  }
  # i_cluster = unique(out$Subtype_Immune_Model_Based)
  # i_order =  order( gsub('\\).*', '', gsub('.*\\(Immune ', '', i_cluster) ), decreasing = TRUE)
  # out$Subtype_Immune_Model_Based = factor(out$Subtype_Immune_Model_Based, levels = i_cluster[i_order])
  dbDisconnect(gitrconn)
  out %>% droplevels %>% data.frame(check.names = FALSE)
}


test_gitr = function(n, phenos = TRUE){
  testconn = RSQLite::dbConnect(RSQLite::SQLite(), dbname = gitrdb, flags = RSQLite::SQLITE_RO )
  allprobes = tbl(testconn, 'allprobes')
  sampled = allprobes %>% pull(probe) %>% sample(n)
  time1 = Sys.time()
  out = gitr(sampled, phenos = phenos)
  time2 = Sys.time()
  print(head(out,1))
  print(time1)
  print(time2)
  dbDisconnect(testconn)
}
