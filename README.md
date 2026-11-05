# hbcd_mrs_to_nii_conversion

Routines used in HBCD to convert MRS archives from GE, Philips, Siemens to BIDS format

## Usage

Install the dependencies in `environment.yml`, or build the Docker image:

```sh
docker build -t hbcd-mrs .
docker run --rm -v "$PWD:/data" hbcd-mrs /data/PSCID_DCCID_VisitID.zip /data/output
```

For a local run with the Python environment activated:

```sh
bash spec2nii_HBCD_batch.sh PSCID_DCCID_VisitID.zip ./output
```

Archive names follow `PSCID_DCCID_VisitID_..._StudyInstanceUID.zip`.
The optional study UID defaults to the string `None` when absent. Outputs go
to `output/sub-DCCID/ses-VisitID/mrs`. Archive extraction requires `unar`.

## Philips DICOM

DICOM-only archives inspect the DICOM `Manufacturer` before conversion:
Philips uses `spec2nii philips_dcm`, and Siemens uses `spec2nii dicom`.
Mixed-vendor archives and missing or unsupported manufacturers fail explicitly.
The Philips path was tested
with version 0.8.7, pinned in both Docker and the Conda environment.
Uppercase `.DCM`, nested ZIPs/folders, and macOS `__MACOSX`/AppleDouble files
are handled. Existing SDAT, data/list, TWIX, and GE inputs retain their
conversion paths and take precedence over accompanying DICOM files.

Philips private frame flag `(2005,1304)` identifies metabolite and
water-reference frames, including when water phase correction is `NO`.

The shell script's inline DICOM preprocessing reuses spec2nii's Philips HYPER
SDAT splitter: 32 short-TE metabolite frames, followed by four interleaved
HERCULES editing conditions. Water references alternate 80/35 ms, starting
with 80 ms. This produces short-TE and HERCULES metabolite datasets and
their corresponding water references.

**Acquisition assumption:** the 35/80-ms partition, reference alternation,
and A/B/C/D editing order follow the existing HYPER convention. Per-frame
DICOM tags may not independently describe this ordering. Confirm
this layout with the acquisition site before using the outputs for analysis.
Incomplete editing cycles or unpaired references are rejected rather than
silently discarded. Other Philips protocols are classified by 30/35 or
80-ms echo time; unsupported acquisitions fail explicitly.

Outputs are anonymized with spec2nii, identifying source filenames are removed
from metadata, and spectral-width sidecars are updated. Repeating a conversion
with the same archive study UID reuses its run number. The Philips DICOM path
uses the existing shared naming, anonymization, sidecar, and final-reporting
steps. Input DICOMs and archives are not modified or anonymized.

## Tests

```sh
python -m unittest discover -s tests -v
```

Tests cover manufacturer routing, metadata exclusions, HYPER frame order,
and invalid frame layouts. Test inputs are generated in memory or temporary
directories; no external data files are required.