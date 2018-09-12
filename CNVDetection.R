#####################Load in R libraries#########################
library(Seurat)
library(Matrix)
library(stringr)
library(DiagrammeR)
library(fifer)
library(NMF)
library(ComplexHeatmap)
library(RColorBrewer)
library(colorRamps)
library(circlize)
library(ggplot2)
library(enrichR)
library(cluster)
library(tidyr)
library(mygene)
library(dplyr)
library(igraph)
library(Rtsne)
library(scales)
library(biomaRt)
library(diptest)


#####################Load in dependencies#########################

gencode = read.table("/Volumes/ahg_regevdata2/projects/Glioma_differentiation/resources/gencode_v19_gene_pos.txt")

#######################CNV detection#########################
#Code is adapted from Chris Rodman, Summer 2018.
#This function will take as input a filtered, normalized, tpm matrix (e.g. from tpm.process) and a gencode gene annotation file. It will output a data frame
#Containing the inferred CNVs based on the approach developed by Itay Tirosh.

infer.cnv = function(tpm, gencode)
{
        #Gencode is ordered.
        colnames(gencode) = c("Gene", "Chr", "Start", "End")
        gencode$Gene = as.character(gencode$Gene)
        
        #Order data by chromosome.
        tpm = mutate(tpm, Gene = rownames(tpm))
        Ecnv = inner_join(gencode, tpm, by = "Gene")
        genes = Ecnv[,1:4]
        Ecnv = dplyr::select(Ecnv, -Gene, -Chr, -Start, -End)
        rownames(Ecnv) = genes$Gene
        
        #convert numbers >3 to 3, numbers <-3 to -3.
        Ecnv = replace(Ecnv, Ecnv < -3, -3)
        Ecnv = replace(Ecnv, Ecnv > 3, 3)
        
        #Calculate moving average.
        Ecnv_smoothed = integer(0)
        
        chromosomes = unique(genes$Chr)
        for (j in 1:(length(chromosomes)-1))
        { 
                print(paste0("Running InferCNV for Chromosome ", chromosomes[j], "."))
                Ecnv_Chr = Ecnv[genes$Chr == chromosomes[j],]
                genes_temp = genes[genes$Chr == chromosomes[j],]
                
                temp = integer(0)        
                for (i in 51:(nrow(Ecnv_Chr)-50))
                { 
                        temp = rbind(temp, apply(Ecnv_Chr[i-50:i+50,], 2, mean))
                }
                temp = data.frame(Chr = rep(chromosomes[j], nrow(temp)), Gene = genes_temp$Gene[51:(nrow(Ecnv_Chr)-50)], 
                                  Start = genes_temp$Start[51:(nrow(Ecnv_Chr)-50)], End = genes_temp$End[51:(nrow(Ecnv_Chr)-50)], temp)
                Ecnv_smoothed = rbind(Ecnv_smoothed, temp)
        }
        
        #Scale data. Column 1 contains Chromosome information. Column 2 contains gene names.
        Ecnv_smoothed [,-c(1,2,3,4)] = scale(Ecnv_smoothed[,-c(1,2,3,4)], center = T, scale = F)
        
        return(Ecnv_smoothed)
}

#This function will take as input copy number information as determined from exome-seq, and match it to the inferred
#CNV as determined from RNA-seq (infer.cnv function). This allows plotting of both together, and the calculation of malignant cell
#thresholds (id.malignant function). The input is the output of infer.cnv, and a list of exome-seq segtab files.
match.exome.cnv = function(Ecnv_smoothed, exome_cnv_files)
{
        exome_cn_labels = gsub("_pair_2.segtab.txt", "", exome_cnv_files)
        exome_cn_labels = gsub("_pair.segtab.txt", "", exome_cn_labels)
        genes = Ecnv_smoothed[,1:4]
        #If there is no CNV inference data from exome, assign the copy number as 2 as default.
        genes_cn = matrix(rep(2, nrow(genes)*length(exome_cnv_files)), nrow = nrow(genes))
        
        colnames(genes_cn) = exome_cn_labels
        
        for (k in 1:length(exome_cnv_files))
        {
                test = read.csv(paste0("~/Suva Lab/Dana Project 1/EXOME/", exome_cnv_files[k]), sep="\t")[,c(1,2,3,4,6,9,10)]
                test = mutate(test, cn_calc = 2*total_copy_ratio)
                
                #annotate the genes vector with the copy number state from exome-seq data.
                
                for (i in 1:nrow(genes))
                {
                        chr = gsub("chr", "", genes[i,]$Chr)
                        
                        if (chr %in% test$Chromosome)
                        { 
                                temp_test = test[test$Chromosome == chr,]
                                loc = which(genes$Start[i] >= temp_test$Start.bp & genes$End[i] <= temp_test$End.bp)
                                
                                #If a gene spans two regions, take the average of the two regions.
                                if (length(loc) == 0)
                                {
                                        loc.A = tail(which(genes$Start[i] >= temp_test$Start.bp),1)
                                        loc.B = loc.A + 1
                                        genes_cn [i,k] = mean(temp_test$cn_calc[loc.A], temp_test$cn_calc[loc.B])
                                }else{ 
                                        genes_cn [i,k] = temp_test$cn_calc[loc]
                                }
                        }
                }
                #rescale.
        }
        genes_cn = log2(genes_cn/2)
        return(genes_cn)
}

#This function identifies cells as malignant based on their sum of squares of CNV signals across the genome, and based
#on the correlation with the CNVs defined by exome-seq (approach from Filbin et. al., Science). Ecnv_smoothed is the output of infer.cnv function, 
#malignant is a vector of malignant cell names as defined by gene expression.
#genes_cn is the output of match.exome.cnv function. sample_ident is pre-defined.
#The output of this function is a vector of cell names identified as being malignant based
#on the specified cutoffs. The function also generates a plot of CNV signal correlation vs CNV signal strength for each sample.
#If genes_cn is not supplied, the method will instead use correlation with the average CNV signal across all cells.

id.malignant = function(Ecnv_smoothed, malignant_exprs, sample_ident, plot_path = "figures/", genes_cn = 0, signal_cutoff = 0.02, correlation_cutoff = 0.2)
{
        correlation = Ecnv_smoothed[,-c(1,2,3,4)]
        #Retrieve sample IDs.
        Sample = sample_ident
        
        #remove data for which there is no exome data.
        if (genes_cn != 0)
        { 
                correlation = correlation[,Sample %in% colnames(genes_cn)]
        }
        
        unique_samples = unique(Sample)
        
        #The following vector is boolean, stores the locations of all malignant cells by cnv correlation.
        malignant = vector()
        #The following vector is for storing cnv_correlations with exome.
        cnv_correlations = vector()
        
        #if exome cnv is not supplied, calculate correlation with average inferred CNV signal.
        if(genes_cn == 0)
        {
                for (i in 1:length(unique_samples))
                {  
                        temp = correlation[,Sample == unique_samples[i]]
                        temp_malignant_exprs = temp[,colnames(temp) %in% malignant_exprs]
                        genes_cn = rowMeans(temp_malignant_exprs)
                        temp_cnv_correlations = apply(temp, 2, function(x) cor(x, genes_cn))
                        cnv_correlations = c(cnv_correlations, temp_cnv_correlations)
                        temp_malignant = temp_cnv_correlations >= correlation_cutoff
                        malignant = c(malignant,temp_malignant)
                }
        } else {
                for (i in 1:length(unique_samples))
                {
                        #if exome cnv is supplied, calculate correlation with exome cnv as ground truth.
                        temp = correlation[,Sample == unique_samples[i]]
                        temp_exome = genes_cn[,colnames(genes_cn) == unique_samples[i]]
                        temp_cnv_correlations = apply (temp, 2, function(x) cor(x, temp_exome))
                        cnv_correlations = c(cnv_correlation, temp_cnv_correlations)
                        temp = temp_cnv_correlations >= correlation_cutoff
                        malignant = c(malignant, temp)
                }}
        
        #Calculate total cnv signal.
        cnv_signal = apply(correlation,2,function(x) sum(x^2)/length(x))
        
        #Filter by cnv_signal, and correlation.
        cnv_signal_malignant = cnv_signal >= signal_cutoff
        malignant = malignant & cnv_signal_malignant
        malignant = colnames(correlation)[malignant]
        
        #Generate plots of CNV correlation vs CNV signal strength.
        
        for (i in 1:length(unique_samples))
        {
                temp.a = cnv_signal[Sample == unique_samples[i]]
                temp.b = cnv_correlations[Sample == unique_samples[i]]
                
                pdf(paste0(plot_path, unique_samples[i], " CNV QC plot.pdf"), width = 7,height=7)
                toplot = data.frame(temp.a,temp.b)
                plot = ggplot(toplot,aes(x = temp.a, y = temp.b)) + geom_point()
                plot = plot + xlab("CNV signal") + ylab("CNV correlation with Exome-Seq")
                plot = plot + geom_hline(yintercept = correlation_cutoff, color = "red")
                plot = plot + geom_vline(xintercept = signal_cutoff, color = "red")
                print(plot)
                dev.off()
        }
        return (malignant)
}

#Code is adapted from Chris Rodman, Summer 2018.
#This function takes as input the output of infer.cnv, the output of id.malignant, as well as a vector of cell names corresponding to normal cells
#to be used as controls (oligo). These normal cells can be identified based on marker expression, as well as based on lack of CNV signals 
#(id.malignant). It outputs the inferred CNV data after correction using normal cell signals. For the different methods, "oligo" means to only use
#The oligo cells as baseline. "Both" means to use both cell types as baseline. "all" means return the whole data frame after correction, "malignant"
#means return only the malignant cells after correction.

baseline.correction = function(Ecnv_smoothed, malignant, oligo, method = c("oligo", "both"), output = c("all", "malignant"), noise_filter = 0.2)
{ 
        #Remove the meta info.
        temp = Ecnv_smoothed[,c(1,2,3,4)]
        Ecnv_smoothed = Ecnv_smoothed[,-c(1,2,3,4)]
        
        non_malignant = colnames(Ecnv_smoothed)[!colnames(Ecnv_smoothed) %in% malignant]
        baseline_oligo = Ecnv_smoothed[,colnames(Ecnv_smoothed) %in% oligo]
        baseline_oligo = apply(baseline_oligo, 1, mean)
        
        #for now, presume that non-malignant cells that are not oligos are immune.
        baseline_immune = Ecnv_smoothed[,(colnames(Ecnv_smoothed) %in% non_malignant) & !(colnames(Ecnv_smoothed) %in% oligo)]
        baseline_immune = apply(baseline_immune, 1, mean)
        combined_baselines = data.frame (Oligo = baseline_oligo, Immune = baseline_immune)
        
        baseline_max = apply(combined_baselines, 1, max)
        baseline_min = apply(combined_baselines, 1, min)
        
        Ecnv_smoothed_ref = Ecnv_smoothed
        
        if (method == "oligo")
        {
                print ("Using oligodendrocytes as controls")
                Ecnv_smoothed_ref = Ecnv_smoothed - baseline_oligo
                #apply noise filter.
                Ecnv_smoothed_ref[Ecnv_smoothed_ref < noise_filter & Ecnv_smoothed_ref > -noise_filter] = 0
        }else if(method == "both")
        {
                print ("Using oligodendrocytes and immune cells as controls.")
                for (i in 1:ncol(Ecnv_smoothed_ref)) {
                        Ecnv_smoothed_ref[ , i] = ifelse(Ecnv_smoothed_ref[ , i] > baseline_max + noise_filter, yes = Ecnv_smoothed_ref[ , i] - baseline_max, no = Ecnv_smoothed_ref[ , i])
                        Ecnv_smoothed_ref[ , i] = ifelse(Ecnv_smoothed_ref[ , i] < baseline_min - noise_filter, yes = Ecnv_smoothed_ref[ , i] - baseline_min, no = Ecnv_smoothed_ref[ , i])
                        #apply noise filter
                        Ecnv_smoothed_ref[ , i] = ifelse((Ecnv_smoothed_ref[ , i] < baseline_min + noise_filter) & (Ecnv_smoothed_ref[ , i] > baseline_min - noise_filter), yes = 0, no = Ecnv_smoothed_ref[ , i])
                }
        }else {
                print("Method should be either oligo or both.")
                return (Ecnv_smoothed)
        }
        
        if (output == "all")
        {       #Put back the meta info.
                Ecnv_smoothed_ref = data.frame(temp, Ecnv_smoothed_ref)
                return(Ecnv_smoothed_ref)
        }else if (output == "malignant"){
                Ecnv_smoothed_ref = Ecnv_smoothed_ref[,colnames(Ecnv_smoothed_ref) %in% malignant]
                #Put back the meta info.
                Ecnv_smoothed_ref = data.frame(temp, Ecnv_smoothed_ref)
                return(Ecnv_smoothed_ref)
        }else{
                print("Specify the output as all or malignant.")
                return (Ecnv_smoothed)
        }
}

#This function takes as input a corrected inferCNV table, and a vector of sample identities.
#For each sample, it checks each chromosome for a bimodal distribution of CNV signal. Then, 
#order all cells within each sample by the chromosomes to identify genetic subclones.
#the output of this function is a sorted inferCNV table, which can be plotted using plot.cnv.
sort.subclones = function(Ecnv_smoothed_ref, sample_ident)
{
        Ecnv_data_only = Ecnv_smoothed_ref[,-c(1:4)]
        #this will be the output
        Ecnv_data_out = Ecnv_data_only
        Chr = factor(Ecnv_smoothed_ref$Chr, levels = rev(unique(Ecnv_smoothed_ref$Chr)))
        Chrs = unique(Chr)
        Samples = unique(sample_ident)
        Samples = Samples[!Samples %in% c("Oligodendrocyte", "Macrophages")]
        
        for (i in 1:length(Samples))
        {
                temp = Ecnv_data_only[,sample_ident == Sample[i]] 
                #temp_order stores the clustering assignments for each chromosome.
                temp_order = list()
                for (j in 1:length(Chrs))
                {
                        temp_chr = temp[Chr == Chrs[j],]
                        #Check for bimodality, using Hartigan's dip test.
                        subclonality_check = apply(temp_chr, 2, function(x) sum(x^2))
                        dip_test = dip(subclonality_check)
                        #if bimodal, determine the cutoff point.
                        if (dip_test <= 0.05)
                        {
                                clusters = kmeans(subclonality_check, 2)$cluster
                                temp_order[[j]] = clusters
                        }else{
                                clusters = rep(1, length(subclonality_check))
                                temp_order[[j]] = clusters
                        }
                }
                #convert the ordering to a dataframe.
                ordering = do.call(rbind, temp_order)
                rownames(ordering) = Chrs
                colnames(ordering) = colnames(temp_chr)
                #order the data for the current sample, starting from Chr1.
                ordering = t(ordering)
                #TODO.
                test = list()
                test[[1]] = ordering
                for (i in 1:length(Chrs)) test[[i+1]] = Chrs[i]
                
                test = do.call(dplyr::arrange, test)
        }
        Ecnv_data_out = data.frame(Ecnv_smoothed_ref[,1:4], Ecnv_data_out)
        return(Ecnv_data_out)
        
}
#This function plots the results of the inferred CNV. The input is the output of baseline.correction, and the output of
#match.exome.cnv. If genes_cn is not supplied, only the plot for infer.cnv will be generated. Otherwise, both plots will
#(for infer.cnv and exome cnv) will be grouped together as the output.
plot.cnv = function(Ecnv_smoothed_ref, sample_ident, genes_cn = 0)
{ 
        Chr = factor(Ecnv_smoothed_ref$Chr, levels = rev(unique(Ecnv_smoothed_ref$Chr)))
        Ecnv_smoothed_ref = dplyr::select(Ecnv_smoothed_ref, -Chr, -Gene, -Start, -End)
        #Retrieve sample IDs.
        Sample = sample_ident
        Ecnv_smoothed_ref = Ecnv_smoothed_ref[,order(Sample)]
        
        ha = HeatmapAnnotation (df = data.frame(Sample = Sample[order(Sample)]))
        ha1 = Heatmap(Ecnv_smoothed_ref, 
                      cluster_rows = F, 
                      cluster_columns = F,
                      show_row_names = F,
                      top_annotation = ha,
                      width = 7,
                      show_column_names = F,
                      split = Chr,
                      col = colorRamp2(seq(-0.6, 0.6, length.out=299), rev(colorRampPalette(brewer.pal(11, "RdBu"))(299))))
        
        if (genes_cn != 0)
        { 
                ha2 = Heatmap(genes_cn,
                              cluster_rows = F,
                              cluster_columns = F,
                              show_row_names = T,
                              width = 1,
                              show_column_names = T,
                              split = Chr,
                              show_heatmap_legend = FALSE,
                              col = colorRamp2(seq(-0.6, 0.6, length.out=299), rev(colorRampPalette(brewer.pal(11, "RdBu"))(299))))
                
                return(ha1 + ha2)
        }else{return(ha1)}
}