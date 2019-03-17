library(tidyverse)

## simple? yet flexible signature creation function
## select columns from supplied data
## scale data before function if desired (default: zscale)
## apply any function you would like function (default: median)
## scale data after function if desired (default: no)

sig_fn = function( dat, comp, name = 'sig',
    prescale = scale, postscale = NULL, fun = NULL  ) {
    ## first, define simple default functions
    median_fn = function(x){median(x, na.rm = TRUE)}
    nothing_fn = function(x){x}
    ## default median signatures; no postscale()
    ## handle NULL and FALSE fun and prescale arguments
    if(is.null(fun)){fun = median_fn}
    ## accept FALSE argument to prescale to turn off defaults
    if(isFALSE(prescale)){prescale = nothing_fn}
    ## catch possible "prescale = NULL" argument and set to default
    if(is.null(prescale)){prescale = scale}
    ## default postscale = nothing
    if(is.null(postscale)){postscale = nothing_fn}
    ## create signature
    signature = dat %>%
        select( one_of( comp ) ) %>%
            prescale %>% apply(1, fun) %>% postscale %>%
                data.frame 
    colnames(signature)  = name
    signature
}    

create_signatures = function(data = dat, siglist = decon_signatures) {
    lapply(names(siglist), function(x){
        sig = siglist[[x]]
        function_args = c( dat = quote(data), sig, name = x )
        do.call( sig_fn, function_args )
    }) %>% data.frame
}



if(FALSE){ # tests
    ## test data
    dat = data.frame(EPCAM = 1:10,ESRP1 = rnorm(10),CD8A = 10:1,CD8B = 21:30,
        FOXP3 = 31:40,CCR8 = rnorm(10) + 20 )
    ## test signatures
    test_decon_signatures = list(
        Epi.def = list ( comp = c("EPCAM", "ESRP1") ),
        TCD8.def = list( comp = c("CD8A", "CD8B") ),
        Treg.def = list( comp = c("FOXP3", "CCR8") ),
        Epi.sum = list ( comp = c("EPCAM", "ESRP1"),
            fun =  function(x){ sum(x, na.rm = TRUE) } ),
        Epi.unlog.sum.log = list (
            comp = c("EPCAM", "ESRP1"),
            fun =  function(x){  log2( sum( 2 ** x, na.rm = TRUE)  )  },
            prescale = FALSE )
        )
    ## test sig_fn()
    genelist = c('CD8A', 'CCR8')
    dat
    ## simplest usage
    sig_fn(dat, comp = genelist)
    ## test linear function with weights, no prescaling
    sig_fn(dat, comp = genelist, name = 'cd8ccr8', prescale = FALSE,
           fun = function(x){ ( 0.3 * x["CD8A"] ) + ( 0.6 * x["CCR8"] )  })
    ## test of adding both custom prescale and signature function
    sig_fn(dat, comp = genelist, name = 'cd8ccr82',
           fun = function(x){ ( 0.3 * x["CD8A"] ) + ( 0.6 * x["CCR8"] )  },
           prescale = function(x){scale(x, center = FALSE, scale = TRUE)} )
    ## test create_signatues() with small signature database (list)
    dat
    create_signatures(data = dat, siglist = test_decon_signatures)
}




