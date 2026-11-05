from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np
from nifti_mrs.create_nmrs import gen_nifti_mrs_hdr_ext
from nifti_mrs.hdr_ext import Hdr_Ext
from pydicom.dataset import Dataset, FileDataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian, generate_uid

ROOT = Path(__file__).resolve().parents[1]

# Exercise the exact inline preprocessing block rather than a test-only copy.
script = (ROOT / "spec2nii_HBCD_batch.sh").read_text()
embedded = script.split("<<'PHILIPS_DCM' || exit 1\n", 1)[1].split("\nPHILIPS_DCM\n", 1)[0]
namespace = {"__name__": "philips_dcm_test"}
exec(compile(embedded, "spec2nii_HBCD_batch.sh:PHILIPS_DCM", "exec"), namespace)
split_hyper = namespace["split_hyper"]

detector = script.split("<<'DICOM_FORMAT'\n", 1)[1].split("\nDICOM_FORMAT\n", 1)[0]


class DicomDetectionTests(unittest.TestCase):
    def detect(self, manufacturers, include_metadata=False):
        with tempfile.TemporaryDirectory(prefix="hbcd-detection-") as temporary:
            root = Path(temporary)
            for index, manufacturer in enumerate(manufacturers):
                path = root / f"scan_{index}.DCM"
                file_meta = FileMetaDataset()
                file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
                file_meta.MediaStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.4.2"
                file_meta.MediaStorageSOPInstanceUID = generate_uid()
                dataset = FileDataset(str(path), {}, file_meta=file_meta,
                                      preamble=b"\0" * 128)
                dataset.is_little_endian = True
                dataset.is_implicit_VR = False
                if manufacturer is not None:
                    dataset.Manufacturer = manufacturer
                dataset.save_as(path, write_like_original=False)
            if include_metadata:
                for directory, name in (("__MACOSX", "._scan.DCM"),
                                        (".hidden", "scan.DCM"), ("", "._scan.DCM")):
                    path = root / directory / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b"not DICOM data")
            return subprocess.run([sys.executable, "-c", detector, str(root)],
                                  capture_output=True, text=True)

    def test_philips_routing(self):
        result = self.detect([" Philips Medical Systems ", "PHILIPS"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "philips_dcm")

    def test_siemens_routing(self):
        result = self.detect([" SIEMENS Healthineers "])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "dicom")

    def test_mixed_manufacturers_are_rejected(self):
        result = self.detect(["Philips", "Siemens"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("single DICOM manufacturer", result.stderr)

    def test_missing_and_unsupported_manufacturers_are_rejected(self):
        for manufacturer in (None, "", "GE MEDICAL SYSTEMS"):
            with self.subTest(manufacturer=manufacturer):
                result = self.detect([manufacturer])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unsupported or missing", result.stderr)

    def test_metadata_files_are_ignored(self):
        result = self.detect(["Philips"], include_metadata=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "philips_dcm")


class HyperSplitTests(unittest.TestCase):
    def make_input(self, metabolite_count=128, reference_count=8):
        count = metabolite_count + reference_count
        data = np.broadcast_to(np.arange(count), (1, 1, 1, 16, count)).astype(complex)
        metadata = Hdr_Ext(127.7, "1H")
        metadata.set_dim_info(0, "DIM_DYN")
        image = gen_nifti_mrs_hdr_ext(data, 0.0005, metadata, np.eye(4))
        frames = []
        for index in range(count):
            frame = Dataset()
            frame.add_new((0x2005, 0x1304), "SS", int(index >= metabolite_count))
            frames.append(frame)
        dataset = Dataset()
        dataset.add_new((0x2005, 0x140f), "SQ", frames)
        return image, dataset

    def test_frame_order_and_edit_conditions(self):
        images, names = split_hyper(*self.make_input())
        np.testing.assert_array_equal(images[0][:][0, 0, 0, 0], np.arange(32))
        edited = images[1][:]
        self.assertEqual(edited.shape, (1, 1, 1, 16, 4, 24))
        for condition in range(4):
            np.testing.assert_array_equal(edited[0, 0, 0, 0, condition],
                                          np.arange(32 + condition, 128, 4))
        np.testing.assert_array_equal(images[2][:][0, 0, 0, 0], np.arange(128, 136, 2))
        np.testing.assert_array_equal(images[3][:][0, 0, 0, 0], np.arange(129, 136, 2))
        self.assertEqual(names, ["HYPER_act_hyper_short_te", "HYPER_act_hyper_edited",
                     "HYPER_ref_edited", "HYPER_ref_short_te"])

    def test_incomplete_edit_cycle_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "four-condition"):
            split_hyper(*self.make_input(metabolite_count=127))

    def test_unpaired_references_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "paired"):
            split_hyper(*self.make_input(reference_count=7))

    def test_frame_count_mismatch_is_rejected(self):
        image, dataset = self.make_input()
        dataset[(0x2005, 0x140f)].value.pop()
        with self.assertRaisesRegex(ValueError, "matching"):
            split_hyper(image, dataset)


if __name__ == "__main__":
    unittest.main()