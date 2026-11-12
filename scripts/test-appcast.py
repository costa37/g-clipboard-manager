import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("appcast", Path(__file__).with_name("create-appcast.py"))
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def test_release_metadata_and_signature(self):
        info = {"CFBundleShortVersionString": "0.3.16", "CFBundleVersion": "36", "LSMinimumSystemVersion": "13.0"}
        signature = appcast.base64.b64encode(bytes(64)).decode()
        feed = appcast.create_feed(info, Path("G-Clip-0.3.16-arm64.zip"), signature, 12345)
        item = ET.fromstring(feed).find("channel/item")
        self.assertEqual(item.find(f"{{{appcast.SPARKLE}}}version").text, "36")
        self.assertEqual(item.find(f"{{{appcast.SPARKLE}}}minimumSystemVersion").text, "13.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), appcast.REPOSITORY + "/releases/download/v0.3.16/G-Clip-0.3.16-arm64.zip")
        self.assertEqual(enclosure.get("length"), "12345")
        self.assertEqual(enclosure.get(f"{{{appcast.SPARKLE}}}edSignature"), signature)

    def test_invalid_signatures_rejected(self):
        for signature in ["", "invalid", appcast.base64.b64encode(bytes(32)).decode()]:
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                appcast.create_feed({}, Path("app.zip"), signature, 1)


if __name__ == "__main__":
    unittest.main()
