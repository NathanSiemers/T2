import Foundation

/// The statistical methods the app computes on the device (Stats.swift, StatsMore.swift),
/// with the papers that define them, as full references. The log-rank and Kruskal-Wallis
/// p-values use the chi-square distribution, and the correlations Student's t distribution,
/// as reference distributions only: no further test is computed.
public enum MethodReferences {
    public static let group = "Methods"

    public static let all: [Reference] = [
        Reference(group: group, title: "Nonparametric Estimation from Incomplete Observations",
                  authors: "Kaplan EL, Meier P", journal: "Journal of the American Statistical Association", year: 1958,
                  doi: "10.1080/01621459.1958.10501452",
                  note: "Used for the Kaplan\u{2013}Meier survival curves."),
        Reference(group: group, title: "Evaluation of survival data and two new rank order statistics arising in its consideration",
                  authors: "Mantel N", journal: "Cancer Chemotherapy Reports", year: 1966, pmid: "5910392",
                  note: "Used for the log-rank test that compares survival curves."),
        Reference(group: group, title: "Regression Models and Life-Tables",
                  authors: "Cox DR", journal: "Journal of the Royal Statistical Society, Series B", year: 1972,
                  doi: "10.1111/j.2517-6161.1972.tb00899.x",
                  note: "Used for the hazard ratio of a continuous variable."),
        Reference(group: group, title: "Note on Regression and Inheritance in the Case of Two Parents",
                  authors: "Pearson K", journal: "Proceedings of the Royal Society of London", year: 1895,
                  doi: "10.1098/rspl.1895.0041",
                  note: "Used for the Pearson correlation shown on scatter plots."),
        Reference(group: group, title: "The Proof and Measurement of Association between Two Things",
                  authors: "Spearman C", journal: "The American Journal of Psychology", year: 1904,
                  doi: "10.2307/1412159",
                  note: "Used for the Spearman rank correlation shown on scatter plots."),
        Reference(group: group, title: "Use of Ranks in One-Criterion Variance Analysis",
                  authors: "Kruskal WH, Wallis WA", journal: "Journal of the American Statistical Association", year: 1952,
                  doi: "10.1080/01621459.1952.10483441",
                  note: "Used for the Kruskal\u{2013}Wallis test that compares the groups of a box plot."),
    ]
}
