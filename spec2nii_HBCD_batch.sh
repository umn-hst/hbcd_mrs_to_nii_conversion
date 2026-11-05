#!/bin/bash
ZipLoc=$1
# Function for HBCD spec2nii BIDS conversion on raw data. This function will take an appropriately named zip file:
#	1) Extract the file to the current work directory
# 2) Identify format from files
#	2) Loop over the files running spec2nii
#	3) Use NIfTI header info to identify the acquisitions
#	4) Check dimensions of the HERCULES data and separate HYPER water
#	5) Create BIDS-compliant file names and copy data to the target directory
#
# Inputs:
#	ZipLoc = Path to data zip file
#	OutputDIR = Path to send the data after conversion. Directory will be created and exisiting content will be overwritten
#
#
# Developed on Python 3.9.15 macOS Montery 12.5
#
# DEPENDENCIES:
# Python packages
# spec2nii v0.8.7 (https://github.com/wtclarke/spec2nii)
#
# other packages
# Non unix OS users need to install the following package to expand tar and zip archives:
# unar v1.10.7 (https://theunarchiver.com/command-line)/(https://formulae.brew.sh/formula/unar)
#
# For the data/list and txt based dcm dump you have to install the DCMTK tool to convert txt to dcm:
# dcmtk v3.6.7 (https://dicom.offis.de/dcmtk.php.en)
#
# NOTE:
# Tested formats: sdat (HYPER), twix (XA30/VE11), data/list/dcmtxtdump
#
# TODO: Test for GE p-files, flag to use backup format
#
# first version C.W.Davies-Jenkins, Johns Hopkins 2023
# modifed by Helge Zollner, Johns Hopkins 01-21-23
# 
# CWDJ robustness update 12-20-2025:
#     spec2nii version checker
#     Unzips multi-zip files
#     Slight modification in data/list identification (no longer uses zip files)
#     Removes whitespace from zip filenames for SUID extraction


# Extract info from zip file name
ZipName=$(basename -- "$ZipLoc")
extension="${ZipName##*.}"
ZipName="${ZipName%.*}"
extension2="${ZipName##*.}"
if [[ $extension2 == "tar" ]]; then
ZipName="${ZipName%.*}"
fi
# CWDJ-2025: Remove whitespace from zipfile name
ZipName="${ZipName//[[:space:]]/}"

IFS=$'_'
ZipSplit=($ZipName)
unset IFS;

# Definitions according to the zip file naming conventions:
PSCID=${ZipSplit[0]}
DCCID=${ZipSplit[1]}
VisitID=${ZipSplit[2]}
StudyInstanceUID=${ZipSplit[4]}

if [[ ! $StudyInstanceUID ]]; then
  StudyInstanceUID=None
fi

# Create output directory

OutputDIR="$2"/sub-"$DCCID"/ses-"$VisitID"/mrs

mkdir -p $OutputDIR

# Directory for temporary files:
Staging=$OutputDIR
Staging="$Staging"/temp/
OutputDIRLoop="$OutputDIR"/*

CounterStart=1
CurrentRun=99
if [ -z "$(ls -A $OutputDIR)" ]; then
   echo "Empty"
   IsNewSIUID=1
   MaxRun=0
else
   echo "Not Empty"
   IsNewSIUID=0
   MaxRun=1
fi

for file in $OutputDIRLoop
do
    extension=${file##*.}
    if [[ $extension == "json" ]]; then
      nstring=${#file}
      string_pos=$nstring-10
      string_pos2=$nstring-11
      string2=${file:string_pos2:1}
      if [[ $string2 == "-" ]]; then
        run=${file:string_pos:1}
      else
        run=${file:string_pos2:2}
      fi
      run=$((run + 0))
      echo "$run"
      if [[ "$run" -gt "$MaxRun" ]]; then
        MaxRun=$(($MaxRun + 1))
        echo MaxRun "$MaxRun"
      fi

      SIUID="$(grep -Eo '"[^"]*" *(: *([0-9]*|"[^"]*")[^{}\["]*|,)?|[^"\]\[\}\{]*|\{|\},?|\[|\],?|[0-9 ]*,?' $file)"
      string='"StudyInstanceUID": "'
      SIUID=${SIUID##*$string}
      nstring=${#SIUID}
      SIUID=${SIUID:0:nstring-3}
      echo "$SIUID"
      if [[ "$StudyInstanceUID" != "$SIUID" ]]; then
        echo Is new SIUID
        IsNewSIUID=1
      else
        echo Is old SIUID
        IsNewSIUID=0
        if [[ "$run" -lt "$CurrentRun" ]]; then
          CurrentRun=$run
        fi
        echo CurrentRun: $CurrentRun
      fi

      #echo run: $run
      #echo CounterStart: $CounterStart
    fi
done

if [[ $CurrentRun != "99" ]]; then
  IsNewSIUID=0
fi

if [[ $IsNewSIUID == "1" ]]; then
  echo Inside is New SUID LOOP:
  CounterStart=$(($MaxRun + 1))
else
  echo Inside is old SUID LOOP:
  CounterStart=$CurrentRun
fi
echo Actual Run: $CounterStart
# Unarchive the file (works for zip and tar):
unar $ZipLoc -o $Staging -f -d

# CWDJ-2025: Keep recursively extracting files until we find data, or no more nested zips remain
process_dir() {
    local dir="$1"
    local extension_list=(".data" ".dat" ".7") # List of MRS data extensions

    # Check if we arrived at the data yet
    for ext in "${extension_list[@]}"; do        
        found_files=$(find "$dir" -type f -name "*$ext")
        if [[ -n "$found_files" ]]; then
            echo "Unzipper found files with extension $ext:"
            return
        fi
    done
    # If not MRS data found (passed above check) we proceed, processing all zips in this directory
    shopt -s nullglob # modify "*.zip" behavior to skip zipless directories during recursion
    for z in "$dir"/*.zip; do
        [ -e "$z" ] || continue
        outdir="${z%.*}"
        mkdir -p "$outdir"
        unar -o "$outdir" -f -d "$z"
        rm -f "$z"
        process_dir "$outdir"   # recurse immediately into the new folder
    done
    shopt -u nullglob # unset behavior

    # Recurse into subdirectories
    for sub in "$dir"/*/; do
        [ -d "$sub" ] && process_dir "$sub"
    done
}
process_dir "$Staging"

# Save path to top level directory
TopLevelDIR=$Staging

# Initilize with no format
Format="none"
# Loop over files in temporary directroy
for f in $(find "$TopLevelDIR" -type f -name "*");
do
  tempfile=${f##*/}
  ini=${tempfile:0:1}
  if ! [[ $ini == "." ]] ; then
    # Generate path, filename, and extensions
    path=${f%/*}
    file=${f##*/}
    extension=${f##*.}
    # Identification begins here
    # Philips SDAT/SPAR
    if [[ $extension == "SDAT" ]] || [[ $extension == "sdat" ]]; then
       echo "Temp file found: $f"
       Format="sdat"
    fi
    # Siemens TWIX
    if [[ $extension == "dat" ]]; then
       echo "Temp file found: $f"
       Format="twix"
    fi
    # GE p-files
    if [[ $extension == "7" ]]; then
       echo "Temp file found: $f"
       Format="ge"
    fi
    # Philips data/list/dcmtxtdump following Sandeeps description
    # CWDJ: Now looks for data/list, not zip file.
    if [[ $extension == "data" ]]; then
         echo "Temp file found: $f"
         Format="data"
         path=$Staging
         
         # Move .data/.list pair in temporary directory
          for dl in $(find "$path" -type f -name "*.list");
          do
            tempfile=${dl##*/}
            ini=${tempfile:0:1}
            if ! [[ $ini == "." ]] ; then
              mv -f "$dl" "$TopLevelDIR"/HYPER.list
            fi
          done;
          for dl in $(find "$path" -type f -name "*.data");
          do
            tempfile=${dl##*/}
            ini=${tempfile:0:1}
            if ! [[ $ini == "." ]] ; then
              mv -f "$dl" "$TopLevelDIR"/HYPER.data
            fi
          done;
          # Find dcmtxtdump and convert to DICOM
          for tx in $(find "$Staging" -type f -name "*.txt");
          do
            tempfile=${tx##*/}
            ini=${tempfile:0:1}
            if ! [[ $ini == "." ]] ; then
              mv -f "$tx" "$TopLevelDIR"/dcmdump.txt
            fi
          done;
          # Find dcmjsondump
          for js in $(find "$Staging" -type f -name "*.json");
          do
            tempfile=${js##*/}
            ini=${tempfile:0:1}
            if ! [[ $ini == "." ]] ; then
              mv -f "$js" "$TopLevelDIR"/dcmdump.json
            fi
          done;
          # Find dcm dir
          for dc in $(find "$Staging" -type d -name "dcm");
          do
            tempfile=${dc##*/}
            ini=${tempfile:0:1}
            if ! [[ $ini == "." ]] ; then
              mv -f "$dc" "$TopLevelDIR"/dcm
            fi
          done;
          # Find .sin file
          for si in $(find "$Staging" -type f -name "*.sin");
          do
            tempfile=${si##*/}
            ini=${tempfile:0:1}
            if [[ $tempfile == *"mrs"* ]]; then
              if ! [[ $ini == "." ]] ; then
                mv -f "$si" "$TopLevelDIR"/temp.sin
              fi
            fi
          done;
          txt="$TopLevelDIR"/dcmdump.txt
          jsn="$TopLevelDIR"/dcmdump.json
          dcm="$TopLevelDIR"/dcmdump.dcm
          dcmdir="$TopLevelDIR"/dcm
          sin="$TopLevelDIR"/temp.sin
          if ! [[ -f "$txt" ]]; then
              Format="none"
              echo No dcmdump txt file found
          else
            # Compare off center position
            echo $sin
            centerSin="$(grep 'loc_ap_rl_fh_offcentres' $sin | grep -Eo -- '[+-]?[0-9]+([.][0-9]{1,2})')"
            centerDCM_ap="$(grep '(2005,105a)' $txt | grep -Eo -- '[+-]?[0-9]+([.][0-9]{1,2})')"
            centerDCM_fh="$(grep '(2005,105b)' $txt | grep -Eo -- '[+-]?[0-9]+([.][0-9]{1,2})')"
            centerDCM_rl="$(grep '(2005,105c)' $txt | grep -Eo -- '[+-]?[0-9]+([.][0-9]{1,2})')"
            #Sin file order is ap rl fh and dcm is ap fh rl switching it (hopefully works all the time)
            echo center sin: $centerSin center dcm: $centerDCM_ap $centerDCM_rl $centerDCM_fh
            if [[ "$centerSin" == *"$centerDCM_ap"* ]] &&
               [[ "$centerSin" == *"$centerDCM_rl"* ]] &&
               [[ "$centerSin" == *"$centerDCM_fh"* ]]; then
              echo Center positions match up to digit 2
            else
              echo Oh Boy center positions do not match
              echo Looping over dcm files

              for dc in $(find "$dcmdir" -type f);
              do
                tempfile=${dc##*/}
                ini=${tempfile:0:1}
                if ! [[ $ini == "." ]] ; then
                  tdc="$dcmdir"/"$tempfile".txt
                  eval "dcmdump $dc &> $tdc"
                  centerDCM_ap="$(grep '(2005,105a)' $tdc | grep -Eo -- '[+-]?[0-9]+([.][0-9]{1,2})')"
                  centerDCM_fh="$(grep '(2005,105b)' $tdc | grep -Eo -- '[+-]?[0-9]+([.][0-9]{1,2})')"
                  centerDCM_rl="$(grep '(2005,105c)' $tdc | grep -Eo -- '[+-]?[0-9]+([.][0-9]{1,2})')"
                  centerDCM="$centerDCM_ap $centerDCM_rl $centerDCM_fh"
                  if [[ $centerDCM == *[[:digit:]]* ]]; then
                    echo center sin: $centerSin center dcm: $centerDCM_ap $centerDCM_rl $centerDCM_fh
                    if [[ "$centerSin" == *"$centerDCM_ap"* ]] &&
                       [[ "$centerSin" == *"$centerDCM_rl"* ]] &&
                       [[ "$centerSin" == *"$centerDCM_fh"* ]]; then
                      mv -f "$tdc" "$TopLevelDIR"/dcmdump.txt
                      echo Found a center position match up to digit 2
                      echo $centerSin
                      echo $centerDCM
                      temp="$dcmdir"/stdout.json
                      eval "dcm2json $dc $temp"
                      mv -f "$temp" "$TopLevelDIR"/dcmdump.json
                      # break
                    fi
                  fi
                fi
              done
            fi

            # We have to be sure that InstitutionName and ProtocolName are in the txt files
            echo "(0008,0080) LO [HBCD site]                              #  30, 1 InstitutionName">> $txt
            echo "(0018,1030) LO [WIP HYPER]                              #  10, 1 ProtocolName">> $txt
              eval "dump2dcm $txt $dcm"

       fi
    fi
  fi
done;

# DICOM is a fallback only: accompanying DICOM files must not replace an
# existing raw-data path. Ignore macOS ZIP metadata, not spectroscopy data.
# The extension is shared by vendors, so inspect Manufacturer before dispatch.
# Reject mixed or unsupported vendors rather than send them to the wrong reader.
if [[ $Format == "none" ]] &&
   [[ -n $(find "$TopLevelDIR" -type f -iname '*.dcm' ! -path '*/__MACOSX/*' ! -name '.*' -print -quit) ]] &&
   [[ -z $(find "$TopLevelDIR" -type f \( -name '*.data' -o -name '*.dat' -o -name '*.7' -o -iname '*.sdat' \) -print -quit) ]]; then
  Format=$(python - "$TopLevelDIR" <<'DICOM_FORMAT'
from pathlib import Path
import sys

import pydicom

staging = Path(sys.argv[1])
formats = set()
for path in staging.rglob("*"):
    if not path.is_file() or path.suffix.lower() != ".dcm":
        continue
    if any(part.startswith(".") or part == "__MACOSX"
           for part in path.relative_to(staging).parts):
        continue
    dataset = pydicom.dcmread(path, stop_before_pixels=True,
                             specific_tags=["Manufacturer"])
    manufacturer = str(dataset.get("Manufacturer", "")).strip().lower()
    if manufacturer.startswith("philips"):
        formats.add("philips_dcm")
    elif manufacturer.startswith("siemens"):
        formats.add("dicom")
    else:
        sys.exit("Unsupported or missing DICOM manufacturer; expected Philips or Siemens.")
if len(formats) != 1:
    sys.exit("Expected a single DICOM manufacturer per archive.")
print(formats.pop())
DICOM_FORMAT
  ) || exit 1
fi

echo "############################"
echo Data format: $Format
echo Location of zip file: $ZipLoc
echo Location of output directory: $OutputDIR
echo Temp dir: $Staging
echo PSCID: $PSCID
echo DCCID: $DCCID
echo VisitID: $VisitID
echo StudyInstanceUID: $StudyInstanceUID
S2Nv=$(spec2nii --version)
echo "spec2nii version: $S2Nv"
echo "############################"

# Unable to parse format from files ... skip to end
if [ $Format == "none" ]; then
  echo Unable to identify file format. Check folder structure.
  exit 0
fi

# Based on format, setup spec2nii source and file extensions
case $Format in
    twix)
        CMD="spec2nii twix -e image "
        Ext=".dat"
        ;;
    sdat)
        CMD="spec2nii philips "
        Ext=".sdat"
        # Rename to all caps extensions
        for f in $(find "$TopLevelDIR" -type f -name "*$Ext");
        do
          mv "$f" "${f//sdat/SDAT}";
        done
        for f in $(find "$TopLevelDIR" -type f -name "*spar");
        do
          mv "$f" "${f//spar/SPAR}";
        done
        Ext=".SDAT"
        ;;
    data)
        CMD="spec2nii philips_dl "
        Ext=".data"
        ;;
    ge)
        CMD="spec2nii ge "
        Ext=".7"
        ;;
    dicom)
        CMD="spec2nii dicom "
      Ext=".[dD][cC][mM]"
        ;;
    philips_dcm)
      CMD="spec2nii philips_dcm "
      Ext=".dcm"
      ;;
esac

# Philips DICOM preprocessing produces the same staged HYPER filenames as
# the other Philips formats. The shared loop below then names, anonymizes,
# and exports every acquisition, including the two separate references.
if [[ $Format == "philips_dcm" ]]; then
  # Read run entities structurally for DICOM: the legacy fixed-width lookup
  # above assumes the svs suffix and cannot reliably read mrsref filenames.
  CounterStart=$(python - "$OutputDIR" "$StudyInstanceUID" <<'PHILIPS_RUN'
import json
from pathlib import Path
import sys

maximum = 0
matching = []
for sidecar in Path(sys.argv[1]).glob("*_run-*_*.json"):
    run = int(sidecar.name.split("_run-")[1].split("_")[0])
    maximum = max(maximum, run)
    with sidecar.open() as stream:
        metadata = json.load(stream)
    if metadata.get("StudyInstanceUID", "None") == sys.argv[2]:
        matching.append(run)
print(min(matching) if matching else maximum + 1)
PHILIPS_RUN
  ) || exit 1
  DICOMIndex=0
  while IFS= read -r -d '' f; do
    DICOMName="philips_dcm_$DICOMIndex"
    $CMD "$f" --anon -f "$DICOMName" -o "$TopLevelDIR" || exit 1
    # Enhanced Philips exports can mix metabolites and references even when
    # water phase correction is NO. Use the private per-frame reference flag.
    # Echo/edit ordering still follows the established HYPER convention:
    # 32 short-TE scans, four-condition edited cycles, alternating 80/35-ms refs.
    # Per-frame echo tags may not independently describe this ordering.
    python - "$f" "$TopLevelDIR" "$DICOMName" <<'PHILIPS_DCM' || exit 1
from pathlib import Path
import sys

import numpy as np
import pydicom
from nifti_mrs.create_nmrs import gen_nifti_mrs_hdr_ext
from nifti_mrs.hdr_ext import Hdr_Ext
from nifti_mrs.nifti_mrs import NIFTI_MRS
from spec2nii.Philips.philips import _special_case_hyper


def split_hyper(image, dataset, basename="HYPER"):
    frames = dataset[(0x2005, 0x140f)].value
    data = image[:]
    if data.ndim != 5 or data.shape[4] != len(frames):
        raise ValueError("Expected one dynamic dimension matching the DICOM frame sequence")
    reference = np.array([bool(frame[(0x2005, 0x1304)].value) for frame in frames])
    metabolites = data[..., ~reference]
    water = data[..., reference]
    if metabolites.shape[4] <= 32 or (metabolites.shape[4] - 32) % 4:
        raise ValueError("HYPER requires 32 short-TE frames followed by complete four-condition cycles")
    if water.shape[4] == 0 or water.shape[4] % 2:
        raise ValueError("HYPER requires paired alternating 80/35-ms water references")
    metadata = image.hdr_ext.to_dict()
    metadata.pop("OriginalFile", None)
    header = Hdr_Ext.from_header_ext(metadata)
    images, names = _special_case_hyper(metabolites, image.dwelltime, header,
                                       image.voxToWorldMat, basename + "_act")
    for offset, echo, acquisition in ((0, 0.08, "edited"), (1, 0.035, "short_te")):
        reference_header = header.copy()
        reference_header.set_standard_def("WaterSuppressed", False)
        reference_header.set_standard_def("EchoTime", echo)
        reference_header.set_dim_info(0, "DIM_DYN")
        images.append(gen_nifti_mrs_hdr_ext(water[..., offset::2], image.dwelltime,
                                           reference_header, image.voxToWorldMat,
                                           no_conj=True))
        names.append(basename + "_ref_" + acquisition)
    return images, names


if __name__ == "__main__":
    dataset = pydicom.dcmread(sys.argv[1])
    if "philips" not in str(dataset.get("Manufacturer", "")).lower():
        raise ValueError("Expected Philips spectroscopy DICOM")
    staging = Path(sys.argv[2])
    converted = sorted(staging.glob(sys.argv[3] + "*.nii.gz"))
    if not converted:
        raise ValueError("No Philips DICOM conversion output")
    for source in converted:
        image = NIFTI_MRS(source)
        metadata = image.hdr_ext.to_dict()
        protocol = str(metadata.get("ProtocolName", "")).lower()
        if any(name in protocol for name in ("hyper", "isthmus")):
            if len(converted) != 1:
                raise ValueError("Expected combined HYPER data with frame-level reference flags")
            images, names = split_hyper(image, dataset, "HYPER_" + sys.argv[3])
            for result, name in zip(images, names):
                result.save(staging / name)
            source.unlink()
        else:
            if not any(np.isclose(float(metadata.get("EchoTime", 0)), echo)
                       for echo in (0.03, 0.035, 0.08)):
                raise ValueError("Cannot identify an HBCD acquisition from DICOM echo time")
            metadata.pop("OriginalFile", None)
            result = gen_nifti_mrs_hdr_ext(image[:], image.dwelltime,
                                         Hdr_Ext.from_header_ext(metadata),
                                         image.voxToWorldMat, no_conj=True)
            result.save(source)
PHILIPS_DCM
    rm "$f"
    DICOMIndex=$((DICOMIndex + 1))
  done < <(find "$TopLevelDIR" -type f -iname '*.dcm' ! -path '*/__MACOSX/*' ! -name '.*' -print0)
else
# Loop over files found with the specified extension and perform conversion:
for f in $(find "$TopLevelDIR" -type f -name "*$Ext");
do
  file=${f##*/}
  ini=${file:0:1}
  if ! [[ $ini == "." ]] ; then
      if [ $Format == "sdat" ] ;then
  	    # Need to handle spar.
        FilePath="${f%$Ext}.SPAR"
        FilePath="$f $FilePath"
        if [[ $f == *"act"* ]]; then
          FilePath="$FilePath --special hyper"
        fi
        if [[ $f == *"ref"* ]]; then
          FilePath="$FilePath --special hyper-ref"
        fi
      elif [ $Format == "data" ] ;then
        FilePath="${f%$Ext}.list"
        FilePath="$f $FilePath $dcm"
      else
        #statements
        FilePath="$f"
      fi

      # Run spec2nii initial call:
      eval "$CMD $FilePath -o $TopLevelDIR"

      # Some cleanup:
      if [ $Format == "sdat" ];then
        rm "${f%$Ext}.SPAR"
      fi
      rm "$f"
    fi
done;
fi

# Separate loop for json dump and anonomize

# Declare an empty list of generated Filenames. (ensures no repeated names)
declare -a Filenames=()

# Initialize number of files:
no_files=1
for f in $(find "$TopLevelDIR" -type f -name "*.nii.gz");
do
  file=${f##*/}
  ini=${file:0:1}
  if ! [[ $ini == "." ]] ; then
    # Get header dump from NIfTI file and convert to array:
    Dump=$(eval "spec2nii dump $f")
    IFS=$'\n'
    array=($Dump)
    unset IFS;

    # Initialize relevant dimension variables:
    Coil=0
    Dyn=0
    Edit=0

    # Loop over array to grab for individual fields
    for i in "${array[@]}"
    do
        if [[ $i == *"EchoTime"* ]]; then
	    TE=${i#*:}
	    TE=${TE::5}
  elif [[ $i == *"RepetitionTime"* ]]; then
      TR=${i#*:}
      TR=${TR::5}
      echo TR $TR
        if [[ $Format == "sdat" ]] || [[ $Format == "data" ]]; then
            TR=$((TR / 1000))
        fi
	elif [[ $i == *"dim             :"* ]]; then
	    Dim=${i#*: [}
	    Dim=${Dim%?}
  	    Dim=($Dim)
	elif [[ $i == *"ProtocolName"* ]]; then
	    Prot=${i#*:}
	    Prot=${Prot%?}
  elif [[ $i == *"SequenceName"* ]]; then
        Seq=${i#*:}
        Seq=${Seq%?}
	elif [[ $i == *"TxOffset"* ]]; then
	    Offset=${i#*:}
	    Offset=${Offset%?}
	    if [[ $Offset == *"-1."* ]]; then
	        Suff="svs"
	    elif [[ $Offset == *"0.0"* ]]; then
	        Suff="mrsref"
            fi
	elif [[ $i == *"dim_"* ]]; then
	    # If coil dimension, then see which dimension it specifies:
	    if [[ $i == *"COIL"* ]]; then
		Coil=${i:6:1}
	    elif [[ $i == *"DYN"* ]]; then
		Dyn=${i:6:1}
	    elif [[ $i == *"EDIT"* ]]; then
		Edit=${i:6:1}
	    fi
    elif [[ $i == *"WaterSuppressed"* ]]; then
      WatSup=${i#*:}
	    WatSup=${WatSup::2}
        fi
    done

    # Use prot or filename to decide on acq;
    # Get suffix for hyper sequences
    if [[ $f == *"HYPER"* ]]||[[ $f == *"hyper"* ]]||[[ $f == *"ISTHMUS"* ]]||[[ $f == *"isthmus"* ]]; then
      if [[ $f == *"short_te"* ]]; then
      	Acq="shortTE"
      elif [[ $f == *"edited"* ]]; then
      	Acq="hercules"
      fi
      if [[ $f == *"act"* ]]; then
      	Suff="svs"
      elif [[ $f == *"ref"* ]]; then
      	Suff="mrsref"
      fi
      if [ $Format == "data" ] ;then
        if [[ $f == *"edited"* ]] ||[[ $f == *"short_te"* ]]; then
        	Suff="svs"
        elif [[ $f == *"ref"* ]]; then
        	Suff="mrsref"
        fi
      fi
    else
      echo Prot $Prot
      echo TE $TE
      if [[ $Prot == *"PRESS"* ]]||[[ $TE == *"0.03"* ]]; then
      	Acq="shortTE"
      elif [[ $Prot == *"HERC"* ]]||[[ $TE == *"0.08"* ]]; then
      	Acq="hercules"
      fi
      echo Acq $Acq
    fi

    if [[ $f == *"HYPER"* ]]||[[ $f == *"hyper"* ]]||[[ $f == *"ISTHMUS"* ]]||[[ $f == *"isthmus"* ]]; then
      if [ $Format == "data" ] ;then
        if [[ $f == *"ref"* ]]; then
          eval "mrs_tools split --file $f --dim DIM_USER_0 --indices 0 1 2 3 --output $TopLevelDIR"
        fi
      fi
    fi

    # For GE data only
    if [ $Format == "ge" ];then
      if [[ $Prot == *"press"* ]] ||[[ $Prot == *"PRESS"* ]]; then
        Acq="shortTE"
      elif [[ $Prot == *"hermes"* ]] ||[[ $Prot == *"HERMES"* ]]; then
        Acq="hercules"
      fi
      if [[ $WatSup == *"T"* ]]; then
        Suff="svs"
      else
        Suff="mrsref"
      fi
    fi

    # DICOM headers encode suppression directly; do not rely on TxOffset or
    # a vendor filename to distinguish ordinary SVS and water references.
    if [[ $Format == "philips_dcm" ]]; then
      if [[ $WatSup == *"T"* ]]; then
        Suff="svs"
      else
        Suff="mrsref"
      fi
    fi

    echo Suffix $Suff
    # NAMING CONVENTION FOR OUTPUT DATA
    # Initialize run counter:
    Counter=$CounterStart
    BIDS_NAME=/sub-"$DCCID"_ses-"$VisitID"_acq-"$Acq"_"run-$Counter"_"$Suff".nii.gz

    # If filename is already generated, then iterate the run counter and update filename:
    while [[ "${Filenames[*]}" =~ "${BIDS_NAME}" ]]; do
      ((Counter+=Counter))
      BIDS_NAME=sub-"$DCCID"_ses-"$VisitID"_acq-"$Acq"_"run-$Counter"_"$Suff".nii.gz
    done
    Filenames+=("${BIDS_NAME}")

    OutFile="$OutputDIR"/"$BIDS_NAME"
    # This is for Hyper data
    if ! [[ $f == *"NOI"* ]]; then
      if ! [[ $f == *"water"* ]]; then
        # This is the part for Philips HYPER
        if [ $Format == "data" ];then
          echo "Hyper Philips Metabolites"
        fi
        # Move NIfTI to output folder
        mv -f "$f" "$OutFile"
        # Extract JSON sidecar and anonomize the NIfTI data:
        eval "spec2nii anon $OutFile -o $OutputDIR"
        eval "spec2nii extract $OutFile"
        JSON_BIDS_NAME=sub-"$DCCID"_ses-"$VisitID"_acq-"$Acq"_"run-$Counter"_"$Suff".json
        JsonOutFile="$OutputDIR"/"$JSON_BIDS_NAME"
        nTE=0
        if [[ $Acq == *"shortTE"* ]] && ! [[ $TE == *"0.035"* ]]; then
          nTE=0.035
        fi
        if [[ $Acq == *"shortTE"* ]] && ! [[ $TE == *"0.035"* ]]; then
          nTE=0.035
        fi
        if [[ $Acq == *"hercules"* ]] && ! [[ $TE == *"0.08"* ]]; then
          nTE=0.08
        fi
        # DICOM preprocessing already sets each block's echo and suppression.
        # The legacy echo repair forces WaterSuppressed=True, including refs.
        if [[ $Format != "philips_dcm" ]] && ! [[ $nTE == 0 ]]; then
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
newEchoTime = {"EchoTime": $nTE, "WaterSuppressed": True, "Manufacturer": "Philips"}
HeaderFileData.update(newEchoTime)
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
python -c "$PYCMD"
          # Overwrite orignial json header extension
          eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
        fi


# Update nii-header for Siemens Hyper Sequence if needed
if [ $Format == "twix" ];then
  echo "Hyper Siemens Metabolites"
  if [[ $Prot == *"HYPER"* ]]||[[ $Prot == *"hyper"* ]]||[[ $Prot == *"ISTHMUS"* ]]||[[ $Prot == *"isthmus"* ]]; then
    # water reference
    if [[ $Suff == *"mrsref"* ]]; then
      Offset=0.0
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
newParameter = {"TxOffset": $Offset, "dim_6": "DIM_DYN", "WaterSuppressed": False, "Manufacturer": "Siemens"}
HeaderFileData.update(newParameter)
if "dim_6_info" in HeaderFileData: del HeaderFileData["dim_6_info"]
if "dim_6_header" in HeaderFileData: del HeaderFileData["dim_6_header"]
if "EditPulse" in HeaderFileData: del HeaderFileData["EditPulse"]
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
    python -c "$PYCMD"
    # Overwrite orignial json header extension
    eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
    fi
    # shortTE
    if [[ $Acq == *"shortTE"* ]] && ! [[ $Suff == *"mrsref"* ]]; then
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
newParameter = {"dim_6": "DIM_DYN", "Manufacturer": "Siemens"}
HeaderFileData.update(newParameter)
if "dim_6_info" in HeaderFileData: del HeaderFileData["dim_6_info"]
if "dim_6_header" in HeaderFileData: del HeaderFileData["dim_6_header"]
if "EditPulse" in HeaderFileData: del HeaderFileData["EditPulse"]
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
    python -c "$PYCMD"
    # Overwrite orignial json header extension
    eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
    fi
  fi
fi

# Update nii-header for GE HERCULES Sequence if needed
echo Seq: $Seq
if [[ $Format == "ge" ]] && ! [[ $Seq == *"hbcd2"* ]];then
  echo "GE"
  if [[ $Suff == *"mrsref"* ]]; then   # water reference
      echo "GE water"
      Offset=0.0
      if [[ $Acq == *"shortTE"* ]]; then
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
newParameter = {"TxOffset": $Offset, "dim_5": "DIM_DYN", "dim_6": "DIM_COIL", "dim_7": "DIM_INDIRECT_0", "WaterSuppressed": False, "Manufacturer": "GE"}
HeaderFileData.update(newParameter)
if "dim_6_info" in HeaderFileData: del HeaderFileData["dim_6_info"]
if "dim_6_header" in HeaderFileData: del HeaderFileData["dim_6_header"]
if "EditPulse" in HeaderFileData: del HeaderFileData["EditPulse"]
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
echo "Update GE shortTE ref header"
python -c "$PYCMD"
# Overwrite orignial json header extension
eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
else # Is HERCULES
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
newParameter = {"TxOffset": $Offset, "dim_5": "DIM_COIL", "dim_6": "DIM_DYN", "WaterSuppressed": False, "Manufacturer": "GE"}
HeaderFileData.update(newParameter)
if "dim_6_info" in HeaderFileData: del HeaderFileData["dim_6_info"]
if "dim_6_header" in HeaderFileData: del HeaderFileData["dim_6_header"]
if "EditPulse" in HeaderFileData: del HeaderFileData["EditPulse"]
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
echo "Update GE HERCULES ref header"
python -c "$PYCMD"
# Overwrite orignial json header extension
eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
fi # End if statement short TE or HERCULES water
else   # metabolite data
  echo "GE metabolites"
  if [[ $Acq == *"shortTE"* ]] && ! [[ $Suff == *"mrsref"* ]]; then
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
newParameter = {"dim_5": "DIM_DYN", "dim_6": "DIM_COIL", "dim_7": "DIM_INDIRECT_0", "Manufacturer": "GE"}
HeaderFileData.update(newParameter)
if "dim_6_info" in HeaderFileData: del HeaderFileData["dim_6_info"]
if "dim_6_header" in HeaderFileData: del HeaderFileData["dim_6_header"]
if "EditPulse" in HeaderFileData: del HeaderFileData["EditPulse"]
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
    echo "Update GE shortTE Metabolites"
    python -c "$PYCMD"
# Overwrite orignial json header extension
eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
    else
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
newParameter = {"dim_5": "DIM_COIL", "dim_6": "DIM_DYN", "Manufacturer": "GE"}
HeaderFileData.update(newParameter)
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
  echo "Update GE HERCULES Metabolites"
  python -c "$PYCMD"
  # Overwrite orignial json header extension
  eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
  fi
fi
fi

      else
        echo "Hyper Philips Water"
        echo "HERCULES Philips Water"
        Acq="hercules"
	      BIDS_NAME=sub-"$DCCID"_ses-"$VisitID"_acq-"$Acq"_"run-$Counter"_"$Suff".nii.gz
        OutFile="$OutputDIR"/"$BIDS_NAME"
        sp="$TopLevelDIR"/HYPER_hyper_water_ref_selected.nii.gz
        # Move NIfTI to output folder
        mv -f "$sp" "$OutFile"
        # Extract JSON sidecar and anonomize the NIfTI data:
        eval "spec2nii anon $OutFile -o $OutputDIR"
        eval "spec2nii extract $OutFile"
        JSON_BIDS_NAME=sub-"$DCCID"_ses-"$VisitID"_acq-"$Acq"_"run-$Counter"_"$Suff".json
        JsonOutFile="$OutputDIR"/"$JSON_BIDS_NAME"
        nTE=0
        if [[ $Acq == *"shortTE"* ]] && ! [[ $TE == *"0.035"* ]]; then
          nTE=0.035
        fi
        if [[ $Acq == *"hercules"* ]] && ! [[ $TE == *"0.08"* ]]; then
          nTE=0.08
        fi
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
TR_float=float($TR)
ProtName = HeaderFileData.get("ProtocolName")
HBCD = "-HBCD"
ProtName = ProtName + HBCD
newHeader = {"EchoTime": $nTE, "RepetitionTime": TR_float, "dim_6": "DIM_DYN", "WaterSuppressed": False, "Manufacturer": "Philips","ProtocolName": ProtName}
HeaderFileData.update(newHeader)
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
python -c "$PYCMD"

          # Overwrite orignial json header extension
          eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
    # Add StudyInstanceUID  to the JSON:
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
newHeader = {"StudyInstanceUID": "$StudyInstanceUID"}
HeaderFileData.update(newHeader)
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
python -c "$PYCMD"
        echo "ShortTE Philips Water"
        Acq="shortTE"
	BIDS_NAME=/sub-"$DCCID"_ses-"$VisitID"_acq-"$Acq"_"run-$Counter"_"$Suff".nii.gz
        OutFile="$OutputDIR"/"$BIDS_NAME"
        sp="$TopLevelDIR"/HYPER_hyper_water_ref_others.nii.gz
        # Move NIfTI to output folder
        mv -f "$sp" "$OutFile"
        # Extract JSON sidecar and anonomize the NIfTI data:
        eval "spec2nii anon $OutFile -o $OutputDIR"
        eval "spec2nii extract $OutFile"
        JSON_BIDS_NAME=/sub-"$DCCID"_ses-"$VisitID"_acq-"$Acq"_"run-$Counter"_"$Suff".json
        JsonOutFile="$OutputDIR"/"$JSON_BIDS_NAME"
        nTE=0
        if [[ $Acq == *"shortTE"* ]] && ! [[ $TE == *"0.035"* ]]; then
          nTE=0.035
        fi
        if [[ $Acq == *"hercules"* ]] && ! [[ $TE == *"0.08"* ]]; then
          nTE=0.08
        fi
        if ! [[ $nTE == 0 ]]; then
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
TR_float=float($TR)
ProtName = HeaderFileData.get("ProtocolName")
HBCD = "-HBCD"
ProtName = ProtName + HBCD
newHeader = {"EchoTime": $nTE,"RepetitionTime": TR_float, "dim_6": "DIM_DYN", "WaterSuppressed": False, "Manufacturer": "Philips","ProtocolName": ProtName}
HeaderFileData.update(newHeader)
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
python -c "$PYCMD"

          # Overwrite orignial json header extension
          eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
        fi
      fi
      # Add run number to the JSON:
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
TR_float=float($TR)
ProtName = HeaderFileData.get("ProtocolName")
HBCD = "-HBCD"
ProtName = ProtName + HBCD
newHeader = {"RepetitionTime": TR_float,"ProtocolName": ProtName}
HeaderFileData.update(newHeader)
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
          python -c "$PYCMD"
          eval "spec2nii insert $OutFile $JsonOutFile -o $OutputDIR"
    fi
    # Add StudyInstanceUID  to the JSON:
PYCMD=$(cat <<EOF
import json
jsonHeaderFile = open("$JsonOutFile")
HeaderFileData = json.load(jsonHeaderFile)
jsonHeaderFile.close()
newHeader = {"StudyInstanceUID": "$StudyInstanceUID"}
HeaderFileData.update(newHeader)
file = open("$JsonOutFile", 'w+')
json.dump(HeaderFileData, file, indent=4)
file.close()
EOF
)
python -c "$PYCMD"
    no_files=$((no_files+1))
  fi
done;
no_files=$((no_files-1))

# Some cleanup:
rm -r -f "$Staging"

# Validate the anonymization
for f in $(find "$OutputDIR" -type f -name "*.nii.gz");
do
  file=${f##*/}
  ini=${file:0:1}
  if ! [[ $ini == "." ]] ; then
    # Get header dump from NIfTI file and convert to array:
    Dump=$(eval "spec2nii dump $f")
    IFS=$'\n'
    array=($Dump)
    unset IFS;

    # Initialize relevant dimension variables:
    anon=1
    # Loop over array to grab for individual fields
    for i in "${array[@]}"
    do
     if [[ $i == *"PatientDoB"* ]]; then
	    anon=0
    elif [[ $i == *"PatientName"* ]]; then
	    anon=0
	    fi
    done
  fi
done

python /code/update_spectral_width.py $OutputDIR

# Final message
if (( $no_files == 4 ));then
  echo Success! 4 nii files generated.
  exitcode=1
fi
if (( $no_files < 4 ));then
  echo Warning! $no_files nii files generated. Check MRS archive.
  exitcode=0
fi
if (( $no_files > 4 ));then
  echo Warning! $no_files nii files generated but we expect only 4. Ensure correct job setup.
  exitcode=0
fi
if (( $anon == 1 ));then
  echo De-identification successful.
else
  echo De-identification failed.
  exitcode=2
fi
# Exit code 1 == success, 0 == wrong number of files, 2 == de-idenfication failed
echo $exitcode
