"""Offline release gates for homepage media, accessibility, and byte budgets."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import struct
import unittest

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / 'website'

class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.elements = []
        self.feed(source)
    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))

class WebsiteAssets(unittest.TestCase):
    def setUp(self):
        self.page = Page((SITE / 'index.html').read_text())
        self.gallery = SITE / 'assets/gallery'

    def test_local_references_and_fragment_links_exist(self):
        for source in SITE.glob('*.html'):
            page = Page(source.read_text())
            for _, attrs in page.elements:
                for key in ('src', 'href', 'poster'):
                    if key not in attrs: continue
                    url = urlsplit(attrs[key])
                    if url.scheme or url.netloc: continue
                    relative = unquote(url.path)
                    if relative.startswith('/screenreel/'):
                        path = SITE / relative.removeprefix('/screenreel/')
                    else:
                        path = source.parent / relative if relative else source
                    if path.is_dir(): path /= 'index.html'
                    self.assertTrue(path.is_file(), f'{source.name}: missing {attrs[key]}')
                    if url.fragment:
                        ids = {a.get('id') for _, a in Page(path.read_text()).elements}
                        self.assertIn(url.fragment, ids, f'{source.name}: broken {attrs[key]}')

    def test_ids_are_unique_and_accessible_names_resolve(self):
        ids = [a['id'] for _, a in self.page.elements if 'id' in a]
        self.assertEqual(len(ids), len(set(ids)))
        for _, attrs in self.page.elements:
            for key in ('aria-labelledby', 'aria-describedby'):
                for target in attrs.get(key, '').split(): self.assertIn(target, ids)

    def test_videos_start_muted_and_have_native_controls_and_posters(self):
        videos = [a for tag, a in self.page.elements if tag == 'video']
        self.assertEqual(len(videos), 6)
        for video in videos:
            self.assertNotIn('autoplay', video)
            self.assertEqual(video['preload'], 'none')
            for attr in ('controls', 'muted', 'playsinline', 'poster', 'aria-label'):
                self.assertIn(attr, video)
            self.assertTrue((SITE / video['poster']).is_file())
        buttons = {a['data-play'] for _, a in self.page.elements if 'data-play' in a}
        self.assertEqual(buttons, {v['id'] for v in videos})

    def test_every_video_has_the_same_display_aspect_and_audio_is_labeled(self):
        videos = [a for tag, a in self.page.elements if tag == 'video']
        for video in videos:
            self.assertEqual((video['width'], video['height']), ('1280', '720'))
        audible = {a['data-play'] for _, a in self.page.elements if 'data-audible' in a}
        self.assertEqual(audible, {'music-demo', 'voice-original-demo', 'voice-clean-demo'})
        css = (SITE / 'styles.css').read_text()
        self.assertIn('grid-template-columns:repeat(2,minmax(0,1fr))', css)
        self.assertIn('aspect-ratio:16/9; object-fit:contain', css)

    def test_audio_comparisons_really_contain_sound_tracks(self):
        def child_boxes(data):
            offset = 0
            while offset + 8 <= len(data):
                size, name = struct.unpack('>I4s', data[offset:offset+8])
                header = 8
                if size == 1:
                    size = struct.unpack('>Q', data[offset+8:offset+16])[0]
                    header = 16
                if size == 0: size = len(data) - offset
                self.assertGreaterEqual(size, header)
                self.assertLessEqual(offset + size, len(data))
                yield name, data[offset+header:offset+size]
                offset += size
        for file in self.gallery.glob('*.mp4'):
            handlers = []
            for name, moov in child_boxes(file.read_bytes()):
                if name != b'moov': continue
                for name, trak in child_boxes(moov):
                    if name != b'trak': continue
                    for name, mdia in child_boxes(trak):
                        if name != b'mdia': continue
                        for name, hdlr in child_boxes(mdia):
                            if name == b'hdlr': handlers.append(hdlr[8:12])
            self.assertEqual(handlers.count(b'vide'), 1, file.name)
            self.assertEqual(handlers.count(b'soun'), int(file.stem in {'music', 'voice-original', 'voice-clean'}), file.name)

    def test_screenshot_has_real_dimensions_alt_and_lazy_decode(self):
        screenshots = [a for tag, a in self.page.elements if tag == 'img' and 'gallery/' in a.get('src', '')]
        self.assertTrue(screenshots)
        for attrs in screenshots:
            data = (SITE / attrs['src']).read_bytes()
            self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
            width, height = struct.unpack('>II', data[16:24])
            self.assertEqual((int(attrs['width']), int(attrs['height'])), (width, height))
            self.assertTrue(attrs.get('alt'))
            self.assertEqual(attrs.get('loading'), 'lazy')
            self.assertEqual(attrs.get('decoding'), 'async')

    def test_public_media_stays_within_small_download_budgets(self):
        for file in self.gallery.glob('*'):
            if file.suffix == '.gif': self.assertLess(file.stat().st_size, 650_000, file.name)
            if file.suffix == '.mp4': self.assertLess(file.stat().st_size, 1_000_000, file.name)
            if file.suffix == '.png': self.assertLess(file.stat().st_size, 450_000, file.name)
        self.assertLess(sum(p.stat().st_size for p in self.gallery.glob('*') if p.is_file()), 6_000_000)

    def test_mp4_metadata_precedes_media_for_fast_playback(self):
        files = list(self.gallery.glob('*.mp4'))
        self.assertEqual(len(files), 6)
        for file in files:
            data, boxes, offset = file.read_bytes(), [], 0
            while offset + 8 <= len(data):
                size, name = struct.unpack('>I4s', data[offset:offset+8])
                if size == 1: size = struct.unpack('>Q', data[offset+8:offset+16])[0]
                if size == 0: size = len(data) - offset
                self.assertGreaterEqual(size, 8)
                self.assertLessEqual(offset + size, len(data))
                boxes.append(name)
                offset += size
            self.assertEqual(offset, len(data))
            self.assertLess(boxes.index(b'moov'), boxes.index(b'mdat'), file.name)

    def test_gif_downloads_are_small_real_animations(self):
        files = list(self.gallery.glob('*.gif'))
        self.assertEqual(len(files), 3)
        for file in files:
            data = file.read_bytes()
            self.assertEqual(data[:6], b'GIF89a')
            width, height = struct.unpack('<HH', data[6:10])
            self.assertEqual((width, height), (640, 360))
            self.assertIn(b'NETSCAPE2.0', data, 'loop extension missing')
            self.assertGreater(data.count(b'\x21\xf9\x04'), 1, 'not animated')

    def test_gallery_has_usable_no_script_links_and_no_external_embeds(self):
        links = [a['href'] for tag, a in self.page.elements if tag == 'a' and 'href' in a]
        for name in ('zoom', 'window', 'styles'):
            for extension in ('mp4', 'gif'):
                self.assertIn(f'assets/gallery/{name}.{extension}', links)
        self.assertFalse(any(tag == 'iframe' for tag, _ in self.page.elements))
        self.assertTrue(any(tag == 'dialog' and a.get('aria-label') for tag, a in self.page.elements))

if __name__ == '__main__': unittest.main(verbosity=2)
