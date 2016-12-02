#!/usr/bin/env nextflow

/*
 * Authors       :
 *
 *
 *      Shaun Aron
 *   	Rob Clucas
 *      Eugene de Beste
 *      Scott Hazelhurst
 *      Anmol Kiran
 *      Lerato Magosi
 *      Abayomi Mosaku
 *
 *  On behalf of the H3ABionet Consortium
 *  2015-2016
 *
 *
 * Description  : Nextflow pipeline for Wits GWAS.
 *
 */

//---- General definitions --------------------------------------------------//

import java.nio.file.Paths;
import sun.nio.fs.UnixPath;

def helps = [ 'help' : 'help' ]
params.help = false


def params_help = new LinkedHashMap(helps)



max_plink_cores = params.max_plink_cores 

plink_mem_req = params.plink_process_memory
other_mem_req = params.other_process_memory
pi_hat=params.pi_hat

if (params.help) {
    params.each {
    entry ->
      print "Parameter: <$entry.key>    \t Default: $entry.value"
      if (entry.key == 'help')
          println ""
      else {
        help = params_help.get(entry.key)
        if (help)
          print "\n    $help"
        println ""
      }
  }
  System.exit(-1)
}

//---- Modification of variables for pipeline -------------------------------//

/* Define the command to add for plink depending on whether sexinfo is
 * available or not.
 */
if ( params.sexinfo_available == "false" ) {
  sexinfo = "--allow-no-sex"
  println "Sexinfo not available, command --allow-no-sex\n"
} else {
  sexinfo = ""
  println "Sexinfo available command"
}


// Checks if the file exists
checker = { fn ->
   if (fn.exists())
       return fn;
    else
       error("\n\n-----------------\nFile $fn does not exist\n\n---\n")
}


//------------


raw_ch = Channel.create()
bim_ch = Channel.create()

/* Get the input files -- could be a glob
 * We match the bed, bim, fam file -- order determined lexicographically
 * not by order given, we check that they exist and then 
 * send the all the files to raw_ch and just the bim file to bim_ch */



Channel
   .fromFilePairs("${params.input_dir}/*.{bed,bim,fam}",size:3, flat : true)\
   .ifEmpty { error "No matching plink files" }\
   .map { a -> [checker(a[1]), checker(a[2]), checker(a[3])] }\
   .separate(raw_ch, bim_ch) { a -> [a,a[1]] }



//---- Start Pipeline -------------------------------------------------------//

/* Process to find duplicates. *
 * Inputs:
 * - bim: the bim file
 * Outputs:
 * - duplicates.snps    : A possibly empty file with a list of SNPs
 */
process getDuplicateMarkers {
  memory other_mem_req
  input:
    set file(inpfname) from bim_ch
  output:
    set  file("${base}.dups") into duplicates_ch
  script:
     print inpfname
     base = inpfname.baseName
     outfname = "${base}.dups"
     template "dups.py"
}


public String getBase(fn) {
   x = file("tmp")
   if (fn.getClass() == x.getClass())
      return fn.getBaseName();
   else
      if (fn[0].getClass() == x.getClass())
      	 return fn[0].getBaseName();
      else
         return fn[0];
}	


/*  Process to remove duplicate SNPs.
 * Inputs
 *   -  raw files from from user-specified data
 *   -  list of duplicates comes from getDuplicateMarkers
 * Outputs:
 *   nodups.{bed,bim,fam} (PLINK file without duplicates) and
 *   qc.log log file
 */

process removeDuplicateSNPs {
  memory plink_mem_req
  input:
    file(plinks)	\
      from raw_ch.phase(duplicates_ch){getBase(it) }.map {it.flatten()}

  publishDir params.output_dir, pattern: "$logfile", \
             overwrite:true, mode:'copy'

  output:
    set  file("${nodup}.bed"),file("${nodup}.bim"),file("${nodup}.fam")\
         into (sex_check_ch,missing_ch,het_ch,ibd_prune_ch,remove_inds_ch)
    file (logfile)
  script:
   base    = plinks[0].baseName
   dups    = plinks[3]
   nodup   = "${base}-nd"
   logfile = "${base}-0002-dups.log"
   """
    plink --bfile $base $sexinfo --exclude $dups --make-bed --out $nodup
    mv ${nodup}.log $logfile
   """
}





/* Process to identify individual discordant sex information.
 * results are put in the output directory
 */
process identifyIndivDiscSexinfo {
  memory other_mem_req
  input:
     file(plinks) from sex_check_ch

  publishDir params.output_dir, overwrite:true, mode:'copy'

  output:
     set val(base), file(logfile) into failed_sex_check
  script:
    base = plinks[0].baseName
    logfile= "${base}-failed.sexcheck"
    if (params.sexinfo_available == "true")
    """
       plink --bfile $base --check-sex  --out $base
       if grep -Rn 'PROBLEM' ${base}.sexcheck > $logfile; then
         echo 'Discordant sex info found'
       else
         echo 'No discordant sex info found'
       fi

    """
    else
     "echo 'No sex information available to check'  > $logfile"

}


// Find missingness statistics for the plink file
process calculateSampleMissing {
  memory plink_mem_req
  input:
     file(plinks) from missing_ch

  publishDir params.output_dir, overwrite:true, mode:'copy'

  output:
     set file("${imiss}.imiss") into\
         (plot1_ch_miss,missing2_ch,miss_het_ch)
  script:
     base = plinks[0].baseName
     imiss= "${base}"
     """
       plink --bfile $base $sexinfo --missing --out $imiss
     """
}



// But for the  moment let's deal with heterozygosity

process calculateSampleHetrozygosity {
   memory plink_mem_req
   input:
      file(nodups) from het_ch

   publishDir params.output_dir, overwrite:true, mode:'copy'

   output:
      file("${hetf}.het") into (hetero_check_ch, plot1_ch_het)
   script:
      base = nodups[0].baseName
      hetf = "${base}"
   """
     plink --bfile $base $sexinfo --het  --out $hetf
   """
}



process generateMissHetPlot {
  memory other_mem_req
  errorStrategy 'ignore'

  input:
    set file(imiss), file(het) from \
        plot1_ch_miss.phase(plot1_ch_het) { getBase(it) }
  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"

  output:
    file('*.pdf')   into pictures_ch

  script:
    base = imiss.baseName
    pairs   = "${base}-pairs.imiss-vs-het.pdf"
    meanhet = "${base}-meanhet_plot.pdf"
    template "miss_het_plot_qcplink.R"
}



// Find those who have too high missingness, or bad heterozygosity
process getBadIndivs_Missing_Het {
  errorStrategy 'ignore'
  memory other_mem_req
  input:
   set file(imiss), file(het) from \
       miss_het_ch.phase(hetero_check_ch) { getBase(it) }
  output:
    set val(base), file(outfname) into failed_miss_het

  script:
    base = het.baseName
    outfname = "${base}-fail_miss_het_qcplink.txt"
    template "select_miss_het_qcplink.pl"

}

/* We are going to check for related individuals and remove them */

// first, in computing relatedness do we ignore high LD regions?

if (params.high_ld_regions_fname != "")
   ldreg_ch=Channel.fromPath(params.plink_inputpath+params.high_ld_regions_fname)
else
   ldreg_ch=Channel.value("dummy") //If not, create dummy channel



// Get which SNPs should be pruned for IBD
process pruneForIBD {
	// multi-threaded plink -- probably 2 core optimal, maybe 3
  cpus max_plink_cores
  memory plink_mem_req
  input:
    file plinks from ldreg_ch.cross(ibd_prune_ch) {true} .map { it.flatten() }
  output:
    file "${outf}.genome" into sort_ibd_ch1,sort_ibd_ch2
  script:
    nodups = plinks[1].baseName
    ldreg  = plinks[0]
    outf   = "${nodups}"
    if (params.high_ld_regions_fname != "")
      range = "--range --exclude $ldreg"
    else
      range =""
    """
      plink --bfile $nodups --threads $max_plink_cores --autosome $sexinfo $range --indep-pairwise 50 5 0.2 --out ibd
      plink --bfile $nodups --threads $max_plink_cores --autosome $sexinfo --extract ibd.prune.in --genome --out ibd_prune
      plink --bfile $nodups --threads $max_plink_cores --autosome $sexinfo --extract ibd.prune.in --genome --min $pi_hat --out $outf
      echo DONE
     """

}



// run script to find related individuals
//  Future - perhaps replaced with Primus
process findRelatedIndiv {
  errorStrategy 'ignore'
  memory other_mem_req
  input:
     set file (missing), file (ibd_genome) from \
         missing2_ch.phase(sort_ibd_ch2) { getBase(it) }
  output:
     set val(base), file(outfname) into related_indivs

  script:
     base = missing.baseName
     outfname = "${base}-fail_IBD_qcplink.txt"
     template "run_IBD_QC_qcplink.pl"


}


def phasemerge = {
     x,y -> x+y[1..-1]
}



process removeQCIndivs {
  memory plink_mem_req
  input:
    file(inps) from\
      failed_miss_het.phase(related_indivs).map { x,y-> phasemerge(x,y)}\
                     .phase(failed_sex_check).map { x,y-> phasemerge(x,y)}
                     .phase(remove_inds_ch) {getBase(it)}
		     .map {it.flatten()[1..-1]}
  script:
  output:
     file("${out}.{bed,bim,fam}") into\
         (clean00_ch1,clean00_ch2,clean00_ch3, clean00_ch4)

  script:
   f_miss_het   =inps[0]
   rel_indivs   =inps[1]
   f_sex_check_f=inps[2]
   base = inps[3].baseName
   out  = "${base}-c"
    """
     cat $f_sex_check_f $rel_indivs $f_miss_het | sort -k1 | uniq > failed_inds
     plink --bfile $base $sexinfo --remove failed_inds --make-bed --out $out
  """
}




process calculateMaf {
  memory plink_mem_req
  input:
    file(plinks) from clean00_ch1

  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.frq"

  output:
    file "${base}.frq" into maf_plot_ch

  script:
    base = plinks[0].baseName
    """
      plink --bfile $base $sexinfo  --freq --out $base
    """
}


process generateMafPlot {
  memory other_mem_req
  input:
    file frqfile from maf_plot_ch
  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"

  output:
    file ofname

  script:
    base    = frqfile.baseName
    ofname  = "${base}-maf_plot.pdf"
    template "maf_plot_qcplink.R"
}


// Repeat computation of missingness on QCd data
process calculateSnpMissigness {
  memory plink_mem_req
  input:
   file (plinks)  from clean00_ch2

  output:
   file "${base}.lmiss" into clean_miss_plot_ch

  script:
   base=plinks[0].baseName
   """
     plink --bfile $base $sexinfo --missing --out $base
   """
}


process generateSnpMissingnessPlot {
  memory other_mem_req
  input:
    file lmissf from clean_miss_plot_ch

  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"

  output:
    file output

  script:
    input  = lmissf
    base   = lmissf.baseName
    output = "${base}-snpmiss_plot.pdf"
    template "snpmiss_plot_qcplink.R"
}

// Find differential missingness between cases and controls; also compute HWE scores
process calculateSnpSkewStatus {
  memory plink_mem_req
  cpus max_plink_cores
  input:
    file(plinks)  from clean00_ch3
  output:
    file "${base}.missing" into (clean_diff_miss_plot_ch1,clean_diff_miss_ch2)
    file "${base}.hwe" into hwe_scores_ch
  script:
   base = plinks[0].baseName
   """
    plink --threads ${max_plink_cores} --bfile $base $sexinfo --test-missing mperm=20000 --hardy --out $base
   """
}


process generateDifferentialMissingnessPlot {
   memory other_mem_req
   input:
     file clean_missing from clean_diff_miss_plot_ch1
   publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"
   output:
      file output into snpmiss_plot_ch
   script:
       input = clean_missing
       base  = clean_missing.baseName
       output= "${base}-snpmiss_plot.pdf"
       template "diffmiss_splot_qcplink.R"

 }


// Find those SNPs that have diff missingness in cases & controls
process findSnpExtremeDifferentialMissingness {
  memory other_mem_req
  input:
    file clean_missing from clean_diff_miss_ch2
  output:
     set val(base), file(failed) into bad_snps_ch
  script:
    cut_diff_miss=params.cut_diff_miss
    missing = clean_missing
    base    = missing.baseName
    failed  = "${base}-failed_diffmiss.snps"
    template "select_diffmiss_qcplink.pl"
}

// Find HWE scores of each SNP
process findHWEofSNPs {
  memory other_mem_req
  input:
     file hwe from hwe_scores_ch
  output:
     file output  into unaff_hwe

  script:
    base   = hwe.baseName
    output = "${base}-unaff.hwe"
    """
      head -1 $hwe > $output
      grep 'UNAFF' $hwe >> $output
    """
}

process generateHwePlot {
  memory other_mem_req
  input:
    file unaff from unaff_hwe
  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"
  output:
    file output into devnull1

  script:
    input  = unaff
    base   = unaff.baseName
    output = "${base}-hwe_plot.pdf"
    template "hwe_plot_qcplink.R"
}


process removeQCPhase1 {
  memory plink_mem_req
  input:
    file inputs  from \
         clean00_ch4\
           .phase(bad_snps_ch) { getBase(it) }\
           .map { x,y -> phasemerge (x,y) }
  publishDir params.output_dir, overwrite:true, mode:'copy'
  output:
    file("$output.{bed,bim,fam}") into result_ch;

  script:
     base=inputs[0].baseName
     bad =inputs[3]
     output = params.output
     """
     # remove really realy bad SNPs and really bad individuals
     plink --bfile $base $sexinfo --exclude $bad --mind 0.2 --make-bed --out temp1
     # remove bad SNPs
     plink --bfile temp1 $sexinfo --geno 0.2 --make-bed --out temp2
     # Now do final QC
     plink --bfile temp2  $sexinfo \
         --autosome \
         --maf $params.cut_maf --mind $params.cut_mind\
          --geno $params.cut_geno --hwe $params.cut_hwe \
         --make-bed --out ${params.output }
  """
}


result_ch.subscribe { print "Completed and produced ${it.baseName}" }
