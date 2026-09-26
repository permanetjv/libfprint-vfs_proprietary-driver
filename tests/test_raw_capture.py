import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "tools" / "raw-capture.py"
SPEC = importlib.util.spec_from_file_location("raw_capture", SCRIPT)
assert SPEC and SPEC.loader
RAW_CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RAW_CAPTURE)


class MetadataValidationTests(unittest.TestCase):
    def test_accepts_exact_grayscale_image(self):
        RAW_CAPTURE.validate_metadata(256 * 512, 256, 512)

    def test_rejects_length_mismatch(self):
        with self.assertRaisesRegex(RAW_CAPTURE.CaptureError, "length mismatch"):
            RAW_CAPTURE.validate_metadata(10, 2, 6)

    def test_rejects_zero_dimension(self):
        with self.assertRaisesRegex(RAW_CAPTURE.CaptureError, "dimensions"):
            RAW_CAPTURE.validate_metadata(0, 0, 0)

    def test_rejects_oversized_dimension(self):
        with self.assertRaisesRegex(RAW_CAPTURE.CaptureError, "exceed"):
            RAW_CAPTURE.validate_metadata(1024, 1024, 1)


if __name__ == "__main__":
    unittest.main()
