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


dsl = list(
    Epi.sig = list( comp = c("EPCAM", "ESRP1")),
    TCD8.sig = list( comp = c("CD8A", "CD8B")),
    Treg.sig = list( comp = c("FOXP3", "CCR8")),
    Tcell.sig = list( comp = c("CD3D", "CD3E", "CD2")),
    Bcell.sig = list( comp = c("CD19", "CD79A", "MS4A1")),
    NK.sig = list(
        comp = c( "KIR2DL1" , "KIR2DL3" , "KIR2DL4" , "KIR3DL1" , "KIR3DL2" , "KIR3DL3" , "KIR2DS4" ),
        fun = function(x){log2(  sum(2 ** x, na.rm = TRUE) + 1 )},
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
    COXup.sig = list( comp = c('IL1A', 'IL1B', 'IL6', 'CSF3', 'CXCL1', 'CXCL2',
                          ## not founc in TCGA: 'CXCL8',
                          'CXCR1', 'CXCR2', 'CCL2', 'VEGFA' )),
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

    ## MERCK
##    GEP scores listed in Table S2A were computed by first normalizing the raw
## counts by subtracting the average of the log10 counts of the house-keeping genes from the log10 count of each of the predictor genes, and then a weighted sum of the normalized predictor gene values was calculated using the weights for each of the 18
## genes (CCL5=0.008346; CD27=0.072293; CD274=0.042853; CD276=-0.0239; CD8A=0.031021; CMKLR1=0.151253; CXCL9=0.074135; CXCR6=0.004313; HLA.DQA1=0.020091; HLA.DRB1=0.058806; HLA.E=0.07175; IDO1=0.060679;
## LAG3=0.123895; NKG7=0.075524; PDCD1LG2=0.003734; PSMB10=0.032999; STAT1=0.250229; TIGIT=0.084767).
    Merck18.sig = list( comp = qw(
                            'CCL5 CD27 CD274 CD276 CD8A CMKLR1 CXCL9 CXCR6 HLA-DQA1 HLA-DRB1 HLA-E IDO1 LAG3 NKG7 PDCD1LG2 PSMB10 STAT1 TIGIT    STK11IP ZBTB34 TBC1D10B OAZ1 POLR2A G6PD ABCF1 C14orf102 UBB TBP SDHA'
        ),
        prescale = function(x) {
            ## convert log2 to log 10
            x = ( 2 ** x ) - 1 
            x = log10( x + 1 )
            x
        },
        fun = function(x){
            control.genes = qw('STK11IP ZBTB34 TBC1D10B OAZ1 POLR2A G6PD ABCF1 C14orf102 UBB TBP SDHA')
            control.mean = mean( x[ control.genes ] )
            x = x - control.mean
            x['CCL5'] * 0.008346  +   x['CD27'] * 0.072293  +  x['CD274'] * 0.042853  +  x['CD276'] * -0.0239  +  x['CD8A'] * 0.031021  +  x['CMKLR1'] * 0.151253  +  x['CXCL9'] * 0.074135  +  x['CXCR6'] * 0.004313  +  x['HLA-DQA1'] * 0.020091  +  x['HLA-DRB1'] * 0.058806  +  x['HLA-E'] * 0.07175  +  x['IDO1'] * 0.060679  +  x['LAG3'] * 0.123895  +  x['NKG7'] * 0.075524  +  x['PDCD1LG2'] * 0.003734  +  x['PSMB10'] * 0.032999  +  x['STAT1'] * 0.250229  +  x['TIGIT'] * 0.084767
        }
                       ),
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
YWHAZ' ) )
    ## TregCD8.sig = list(
    ##     comp = qwc(CD8A, CD8B, FOXP3, CCR8),
    ##     fun = function(x){
    ##         with(x,
    ##              median(CD8A, CD8B, na.rm = TRUE) -
    ##                  median(FOXP3, CCR8, na.rm = TRUE)
    ##              ) }
    ##     ), 
    ## NKCD8 = list(
    ##     comp = c( 'CD8A', 'CD8B', "KIR2DL1" , "KIR2DL3" , "KIR2DL4" , "KIR3DL1" , "KIR3DL2" , "KIR3DL3" , "KIR2DS4" ),
    ##     fun = function(x) {
    ##         with(x,
    ##              median( c(CD8A, CD8B), na.rm = TRUE ) -
    ##                  mean( c(KIR2DL1 , KIR2DL3 , KIR2DL4 , KIR3DL1 , KIR3DL2 , KIR3DL3 , KIR2DS4), na.rm = TRUE )
    ##              ) } )
    )
################################################################
## signatures of signatures - necessary to first have above evaluated? Maybe.

dsl = append(dsl,
    list(
        TregCD8.sig = list(
            comp = c( dsl$Treg.sig$comp, dsl$TCD8.sig$comp ),
            fun = function(x){
                median( x[dsl$Treg.sig$comp], na.rm = TRUE ) -
                    median( x[dsl$TCD8.sig$comp], na.rm = TRUE )
            }
            ),
        NKCD8.sig = list(
            comp = c( dsl$NK.sig$comp, dsl$TCD8.sig$comp ),
            fun = function(x){
                mean( x[dsl$NK.sig$comp], na.rm = TRUE ) -
                    median( x[dsl$TCD8.sig$comp], na.rm = TRUE )
            }
            )

        ) )
        

decon_signature_list = dsl


               
decon_genelist = unique(unlist(sapply(dsl, function(x){ x$comp} ), use.names = FALSE))
