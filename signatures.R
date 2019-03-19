## perlish functions
## qw() break a string into a character vector by space characters
qw = function(x, delim = "[\\s,]+", begin_delim = "^[\\s,]+" ) {
    x = gsub( begin_delim, '', x, perl = TRUE )
    as.character (  unlist( strsplit(x, split = delim, perl = TRUE) )  )
}

## create character list without quotes, but need commas
## simpler than qw(), as it uses R parser
## qwc( a, b )   should return the same as
## c( 'a', 'b' )
qwc = function(...) { as.character( unlist( as.list( match.call() )[ -1 ] ) ) }



decon_signature_list = list(
    Epi.sig = list( comp = c("EPCAM", "ESRP1")),
    TCD8.sig = list( comp = c("CD8A", "CD8B")),
    Treg.sig = list( comp = c("FOXP3", "CCR8")),
    Tcell.sig = list( comp = c("CD3D", "CD3E", "CD2")),
    Bcell.sig = list( comp = c("CD19", "CD79A", "MS4A1")),
    NK.sig = list(
        comp = c( "KIR2DL1" , "KIR2DL3" , "KIR2DL4" , "KIR3DL1" , "KIR3DL2" , "KIR3DL3" , "KIR2DS4" ),
        fun = function(x){log2(sum(2 ** x, na.rm = TRUE))},
        prescale = FALSE,
        postscale = scale   ),
    MGran.sig = list( comp = c("CLEC4D", "CLEC4E", "CLEC6A")),
    Mono.sig = list( comp = c("CD86", "CSF1R", "C3AR1")),
    MFm2.sig = list( comp = c("CD163", "VSIG4", "MS4A4A")),
    pDC.sig = list( comp = c("LILRA4", "CLEC4C")),
    Fib.sig = list( comp = c("COL1A1", "COL1A2", "COL3A1")),
    IFNG.sig = list( comp = c("IFNG")),
    HypVEGFA.sig = list( comp = c('VEGFA', 'STC1')),
    HypCA9.sig = list( comp = c('EGLN3', 'SLC2A1', 'CA9', 'ENO2', 'LDHA')),
    BCAT2.sig = list( comp = c('AXIN2', 'NKD1')),
    BCAT4.sig = list( comp = c('AXIN2', 'NKD1', 'RNF43', 'ZNRF3')),
    BCAT5.sig = list( comp = c('AXIN2', 'NKD1', 'RNF43', 'ZNRF3', 'NOTUM')),
    TGajo.sig =  list( comp = c("CD8A", "CD8B", "CCL2", "CCL3", "CCL4", "CXCL9", "CXCL10", "ICOS", "GZMK", "IRF1", "HLA-DMA", "HLA-DMB", "HLA-DOA", "HLA-DOB")),
    TGaj.sig = list(
        comp = qw('CD8A CCL2 CCL3 CCL4 CXCL9 CXCL10 ICOS GZMK IRF1 HLA-DMA HLA-DMB HLA-DOA HLA-DOB')),
    CyT.sig = list( comp = c('GZMA', 'PRF1')),
    Endo.sig = list( comp = c('CD34','ECSCR','PECAM1','TIE1','CLEC14A')),
    Ribas6.sig = list( comp = c('IFNG', 'CXCL10','CXCL9','HLA-DRA','STAT1')),
    Ribas18.sig = list( comp = c('CD3D','IDO1','CIITA','CD3E','CCL5','GZMK','CD2',
                            'HLA-DRA','CXCL13','IL2RG','NKG7','HLA-E','CXCR6','LAG3','TAGAP','CXCL10','STAT1','GZMB')),
    BMSMagic.sig = list( comp = c('LAG3', 'CD274', 'CD8A', 'STAT1')),
    BMS4.sig = list( comp = c('LAG3', 'CD274', 'CD8A', 'STAT1')),
    BMS2.sig = list( comp = c('LAG3', 'CD274')),
    DC1.sig = list( comp = c('CLEC9A', 'FLT3', 'XCR1')),
    COXup.sig = list( comp = c('IL1A', 'IL1B', 'IL6', 'CSF3', 'CXCL1', 'CXCL2', 'CXCL8', 'CXCR1', 'CXCR2', 'CCl2', 'VEGFA' )),
    ##Neut1.sig = list( comp = c('FPR1', 'CSF3R')),
    ##Neut2.sig = list( comp = c('FPR1', 'CSF3R', 'FCGR3B', 'CEACAM3')),
    Ifn9p.sig = list( comp = c(
                          "IFIT1B",
                          "IFNA21",
                          "IFNW1",
                          "IFNA1",
                          "IFNA14",
                          "IFNA2",
                          "IFNA5",
                          "IFNA6",
                          "IFNA8",
                          "IFNB1",
                          "IFNE",
                          "IFIT1",
                          "IFNK",
                          "CNTFR",
                          "IFIT2",
                          "IFIT3"
        )),
    Ribas10.sig = list( comp = qw(
                            'HLA-DRA
CXCL9
GZMA
PRF1
CCR5
IFNG
CXCL10
IDO1
STAT1
CXCL11' )),
    Nano18.sig =  list( comp = qw(
                            'CXCL9
        CD8A
        IDO1
        STAT1
        PSMB10
        HLA-DQA1
        HLA-DRB1
        CCL5
        CD27
        CXCR6
        CD274
        CD276
        LAG3
        PDCD1LG2
        TIGIT
        CMKLR1
        HLA-E
        NKG7'
        ) ),
    Merck18.sig = list( comp = qw(
                            'CCL5 CD27 CD274 CD276 CD8A CMKLR1 CXCL9 CXCR6 HLA-DQA1 HLA-DRB1 HLA-E IDO1 LAG3 NKG7 PDCD1LG2 PSMB10 STAT1 TIGIT' ) ),
    Qiagen_controls = list( comp = qw(
                                'ACTB
ATP5F1
DDX5
EEF1G
GAPDH
NCL
OAZ1
PPIA
RPL38
RPL6
RPS7
SLC25A3
SOD1
TBP
YWHAZ' )),
    Merck18_algorithm.sig = list( comp = qw(
                                      'CCL5 CD27 CD274 CD276 CD8A CMKLR1 CXCL9 CXCR6 HLA-DQA1 HLA-DRB1 HLA-E IDO1 LAG3 NKG7 PDCD1LG2 PSMB10 STAT1 TIGIT' ) )
)



dsl = decon_signature_list

decon_genelist = unlist(decon_signature_list, use.names=FALSE)



deconfunctions =  list(
    HypVEGFA.sig = function(x) {median(x[names(x) %in% dsl$HypVEGFA.sig])},
    HypCA9.sig = function(x) {median(x[names(x) %in% dsl$HypCA9.sig])},
    TGaj.sig = function(x) {median(x[names(x) %in% dsl$TGaj.sig])},
    CyT.sig = function(x) {median(x[names(x) %in% dsl$CyT.sig])},
    TCD8.sig = function(x) {median(x[names(x) %in% dsl$TCD8.sig])},
    Treg.sig = function(x) {median(x[names(x) %in% dsl$Treg.sig])},
    Tcell.sig = function(x){median(x[names(x) %in% dsl$Tcell.sig])},
    Bcell.sig = function(x){median(x[names(x) %in% dsl$Bcell.sig])},
    ##    NK.sig = function(x) {median(x[names(x) %in% dsl$NK.sig])},
    NK.sig = function(x) {
        set.seed(10538)
        mean(x[names(x) %in% dsl$NK.sig], na.rm = TRUE ) + rnorm(1, 0.16, 0.08)
    },
    ##Treg.sig = function(x) {median(x[names(x) %in% dsl$Treg.sig], na.rm = TRUE)},
    Treg.sig = function(x) {median(x[names(x) %in% dsl$Treg.sig], na.rm = TRUE  ) },
    MGran.sig = function(x) {median(x[names(x) %in% dsl$MGran.sig], na.rm = TRUE )},
    Mono.sig = function(x) {median(x[names(x) %in% dsl$Mono.sig], na.rm = TRUE )},
    MFm2.sig = function(x) {median(x[names(x) %in% dsl$MFm2.sig], na.rm = TRUE )},
    Fib.sig = function(x) {  median(x[names(x) %in% dsl$Fib.sig], na.rm = TRUE )  },
    IFNG.sig = function(x) x[["IFNG"]],
    TregCD8.sig = function(x) {  deconfunctions[["Treg.sig"]](x) - deconfunctions[["TCD8.sig"]](x) },
    NKCD8.sig = function(x) { deconfunctions[["NK.sig"]](x) - deconfunctions[["TCD8.sig"]](x) },
    Ifn9p.sig = function (x) { mean(  x[ names(x) %in% dsl$Ifn9p.sig ], na.rm = TRUE ) },
    Endo.sig = function (x) { mean(  x[ names(x) %in% dsl$Endo.sig ], na.rm = TRUE ) },
    Merck18_algorithm.sig = function(x) {
        ## createdecon will demand scale = FALSE
        ## compute mean of logged housekeeping genes.
        hk_mean = mean( log10 ( 2 ** ( x[ names( x ) %in% dsl$Qiagen_controls] ) + 1 ) , na.rm = TRUE )
        ## get the log10 version of the signature genes
        ## wrapper function processes 1 row at a time
        x = log10 ( (2 ** x) + 1 )
        ## we don't have weights for a weighted average right now
        sum( x / hk_mean, na.rm = TRUE)
    }
)
