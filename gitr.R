

################################################################
## gitr - data retriever

gitr = function(probes, phenos = TRUE, nonormal = TRUE,
    cohort = 'all', conn = con,
    makefactors = TRUE,
    db = 'tcga',
    dbcat = 'tcgacat'
                ) {
    ##print(match.call())
    if(FALSE){ #testing
        probes = c('CD8A', 'CD8B'); phenos = TRUE; nonormal = FALSE; cohort = 'all'; makefactors = TRUE
    }
    probes_orig = probes
    ## test to see if mutations are here, if so add muttest.muttest to probe list to capture wt samples
    if ( any( grepl('\\.mut$|\\.fmut$|mutvaf$', probes))) {
        probes = c( probes, 'muttest.muttest' )
        MUTTEST = TRUE
    } else {
        MUTTEST = FALSE
    }
    tcga = tbl(conn, 'tcga')
    tcgacat = tbl(conn, 'tcgacat')
    samples = pull(tbl(conn, 'samples'), sample)
    mutationsamples = pull( tbl(conn, 'mutationsamples'), sample )
    mygenes = pull( tbl(conn, 'allprobes') , probe )
    ##probes = pull( tbl(conn, 'probes') , probe )
    types = tbl(conn, 'types')
    cohorts = tbl(conn, 'cohorts')
    tcgas = tbl(conn, 'tcgas')
    tcgai = tbl(conn, 'tcgai')
    tcgacati = tbl(conn, 'tcgacati')
    tcgacats = tbl(conn, 'tcgacats')
    ## ##subtype = tbl(conn, 'subtypes')
    ##subtypes = c( "none", subtypes %>% pull(subtype) )
    clin = tbl(conn, 'clin')
    mygenesplus = c( 'subtype', 'cohort', mygenes, 'sample_type')

    ## a catch-all to retrieve more data than possibly requested
    ##probes = unique( c(probes, gsub('\\.[^.]*$', '', probes) ) )
    ## this is now a problem, as we have .sigs, with no parent in probe name
    ## new comment
    ##probes = unique( c( probes,  gsub('\\.[^.]*$', '', probes ) ) )
    print(paste(  'Probes within gitr' ))
    print(as.data.frame(probes))
    out = tbl(con, 'tcga')  %>%
        filter( probe %in% probes ) %>%
            as_tibble %>%
                ## some immune scores are not unique in pancan tables
                ## seems to only be the immune scores
                distinct( sample, probe, type, .keep_all = TRUE ) %>%
                    mutate(subtype = Subtype_Selected, lcohort = cohort, cohort = tumtype)
    print('gitr finished first query')
    ## filter out normals if desired
    if( nonormal )  {
        out = out %>% dplyr::filter( sample_type != "Solid Tissue Normal" )
    }
    ## include only selected cohorts if desired
    if( !is.null(cohort) ) {
        if ( cohort  != "all"  ) {
            print("filtering by cohort")
            print(dim(out))
            print(paste('Cohort', cohort))
            out = out[ out$cohort %in% cohort, ]
            print(paste(unique( out$tumtype)))
            print(dim(out))
        }
    }
    ## mutate probes to add type (accomodate shiny)
    ## but we need to improve this, getting .sig.sig now
    ## below is a band-aid
    ## new commented
    ##out$probe = paste(out$probe, out$type, sep = '.')
    ##out$probe = gsub( "\\.tmb$", '', out$probe)
    ##out$probe = gsub( "\\.rna$", '', out$probe)
    ##out$probe = gsub( "\\.sig$", '', out$probe)
    ## not needed: out$probe = gsub( "\\.estimate$", '', out$probe)
    out = out %>% select( -type ) %>% spread( probe, value )
        outcat = tbl(con, 'tcgacat')  %>%
        dplyr::filter( probe %in% probes & type == 'fmut' ) %>%
            as_tibble %>%
                distinct( sample, probe, type, .keep_all = TRUE )
    ##outcat$probe = paste(outcat$probe, outcat$type, sep = '.')
    outcat = outcat %>% select ( sample, probe, value ) %>%
        spread( probe, value ) 
    out = out %>% left_join(outcat, by = 'sample')
    ## make sample_type a factor
    out$sample_type = factor(out$sample_type,
        levels = c( "Primary Tumor",
            "Recurrent Tumor",
            "Metastatic",
            "Additional - New Primary",
            "Additional Metastatic",
            "Solid Tissue Normal"
                   ) )                      
    ## impute 0 mutation calls
    out = out %>% mutate_at(
        vars( ends_with(".mut") ),
        funs( case_when(
            is.na(.) & sample %in% mutationsamples ~ 0,
            TRUE ~ .  ) )
        )
    out = out %>% mutate_at(
        vars( ends_with(".fmut") ),
        funs( case_when(
            is.na(.) & sample %in% mutationsamples ~ 'wt',
            TRUE ~ .  ) )
        )
    out = out %>% mutate_at(
        vars( ends_with("mutvaf") ),
        funs( case_when(
            is.na(.) & sample %in% mutationsamples ~ 0,
            TRUE ~ .  ) )
        )
    ## make factors
    if( makefactors ) {
        out = out %>% mutate_if(is.character, as.factor)
        out = out %>% mutate_at( dplyr::vars( ends_with('mut') ) , funs(as.factor) )
        out = out %>% mutate_at( dplyr::vars( ends_with('cnc') ) , funs(as.factor) )
    }
    if(MUTTEST){ out = out %>% select( -muttest.muttest ) }
    ##print(out)
    ## order Subtype_Immune_Model_Based
    ##string = 'aljkfdakaj (Immune C4)'
    ##gsub('\\).*', '', gsub('.*\\(Immune ', '', string) )
    ################################################################
    ## horrible code to order some factors - BLAME ERIKA ;)
    i_cluster = unique(out$Subtype_Immune_Model_Based)
    i_order =  order( gsub('\\).*', '', gsub('.*\\(Immune ', '', i_cluster) ), decreasing = TRUE)
    out$Subtype_Immune_Model_Based = factor(out$Subtype_Immune_Model_Based, levels = i_cluster[i_order])
    ###############################################################
    out %>% droplevels %>% data.frame(check.names = FALSE)
}
