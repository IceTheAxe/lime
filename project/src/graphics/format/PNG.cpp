#include <spng.h>
#include <zlib.h>
#include <cstdio>
#include <graphics/format/PNG.h>
#include <graphics/ImageBuffer.h>
#include <system/System.h>
#include <utils/Bytes.h>


namespace lime {


	bool PNG::Decode (Resource *resource, ImageBuffer *imageBuffer, bool decodeData) {

		FILE_HANDLE* file = NULL;
		Bytes* data = NULL;

		if (resource->path) {

			file = lime::fopen (resource->path, "rb");
			if (!file) return false;
		}

		spng_ctx *ctx = spng_ctx_new (0);
		if (!ctx) {
			if (file) lime::fclose (file);
			return false;
		}

		int result = SPNG_OK;

		if (file) {

			if (file->isFile ()) {

				result = spng_set_png_file (ctx, file->getFile ());

			} else {

				data = new Bytes ();
				data->ReadFile (resource->path);
				result = spng_set_png_buffer (ctx, data->b, data->length);

			}

		} else {

			result = spng_set_png_buffer (ctx, resource->data->b, resource->data->length);

		}

		if (result != SPNG_OK) {
			spng_ctx_free (ctx);
			if (file) lime::fclose (file);
			if (data) delete data;
			return false;
		}

		struct spng_ihdr ihdr;
		result = spng_get_ihdr (ctx, &ihdr);

		if (result != SPNG_OK) {
			spng_ctx_free (ctx);
			if (file) lime::fclose (file);
			if (data) delete data;
			return false;
		}

		if (decodeData) {
			size_t imageSize = 0;
			result = spng_decoded_image_size (ctx, SPNG_FMT_RGBA8, &imageSize);

			if (result != SPNG_OK) {
				spng_ctx_free (ctx);
				if (file) lime::fclose (file);
				if (data) delete data;
				return false;
			}

			imageBuffer->Resize (ihdr.width, ihdr.height, 32);

			unsigned char *bytes = imageBuffer->data->buffer->b;
			result = spng_decode_image (ctx, bytes, imageSize, SPNG_FMT_RGBA8, SPNG_DECODE_TRNS);

			if (result != SPNG_OK) {
				spng_ctx_free (ctx);
				if (file) lime::fclose (file);
				if (data) delete data;
				return false;
			}

			imageBuffer->format = BGRA32;
			imageBuffer->premultiplied = true;

			bool transparent = false;

			for (size_t i = 0; i + 3 < imageSize; i += 4) {
				unsigned int r = bytes[i];
				unsigned int g = bytes[i + 1];
				unsigned int b = bytes[i + 2];
				unsigned int a = bytes[i + 3];

				if (a != 255) {
					transparent = true;
					r = (r * a + 127) / 255;
					g = (g * a + 127) / 255;
					b = (b * a + 127) / 255;
				}

				bytes[i] = (unsigned char)b;
				bytes[i + 1] = (unsigned char)g;
				bytes[i + 2] = (unsigned char)r;
			}

			imageBuffer->transparent = transparent;

		} else {

			imageBuffer->width = ihdr.width;
			imageBuffer->height = ihdr.height;

		}

		spng_ctx_free (ctx);
		if (file) lime::fclose (file);
		if (data) delete data;

		return true;

	}


	// zlib 直写 PNG：spng 编码不可用时兜底，保证 Image.encode(PNG) 不会返回空。
	// 只做 filter=None 的 RGBA8，够 launch image / 图标这类纯色或简单图使用。
	static void pngWriteUInt32BE (unsigned char* p, unsigned int v) {

		p[0] = (unsigned char)((v >> 24) & 0xFF);
		p[1] = (unsigned char)((v >> 16) & 0xFF);
		p[2] = (unsigned char)((v >> 8) & 0xFF);
		p[3] = (unsigned char)(v & 0xFF);

	}


	static void pngWriteChunk (unsigned char* out, size_t* offset, const char* type, const unsigned char* data, size_t len) {

		unsigned char* p = out + *offset;
		pngWriteUInt32BE (p, (unsigned int)len);
		memcpy (p + 4, type, 4);
		if (len > 0 && data) memcpy (p + 8, data, len);

		uLong crc = crc32 (0L, Z_NULL, 0);
		crc = crc32 (crc, (const Bytef*)(p + 4), (uInt)(4 + len));
		pngWriteUInt32BE (p + 8 + len, (unsigned int)crc);

		*offset += 12 + len;

	}


	static bool EncodeWithZlib (ImageBuffer* imageBuffer, Bytes* bytes) {

		int width = imageBuffer->width;
		int height = imageBuffer->height;

		if (width <= 0 || height <= 0) return false;

		unsigned char* src = imageBuffer->data->buffer->b;
		if (!src) return false;

		size_t rowBytes = (size_t)width * 4;
		size_t rawLen = (size_t)height * (rowBytes + 1);

		unsigned char* raw = (unsigned char*)malloc (rawLen);
		if (!raw) return false;

		unsigned char* dest = raw;

		for (int y = 0; y < height; y++) {

			*dest++ = 0; // filter: None

			for (int x = 0; x < width; x++) {

				unsigned int r = 0, g = 0, b = 0, a = 0;

				switch (imageBuffer->format) {
					case BGRA32: b = src[0]; g = src[1]; r = src[2]; a = src[3]; break;
					case ARGB32: a = src[0]; r = src[1]; g = src[2]; b = src[3]; break;
					case RGBA32:
					default: r = src[0]; g = src[1]; b = src[2]; a = src[3]; break;
				}

				if (imageBuffer->premultiplied && a != 0 && a != 255) {
					r = (r * 255 + (a / 2)) / a;
					g = (g * 255 + (a / 2)) / a;
					b = (b * 255 + (a / 2)) / a;
					if (r > 255) r = 255;
					if (g > 255) g = 255;
					if (b > 255) b = 255;
				}

				*dest++ = (unsigned char)r;
				*dest++ = (unsigned char)g;
				*dest++ = (unsigned char)b;
				*dest++ = (unsigned char)a;
				src += 4;

			}

		}

		uLongf compressedLen = compressBound ((uLong)rawLen);
		unsigned char* compressed = (unsigned char*)malloc (compressedLen);

		if (!compressed) {
			free (raw);
			return false;
		}

		int zr = compress2 (compressed, &compressedLen, raw, (uLong)rawLen, Z_BEST_SPEED);
		free (raw);

		if (zr != Z_OK) {
			free (compressed);
			return false;
		}

		unsigned char ihdr[13];
		pngWriteUInt32BE (ihdr, (unsigned int)width);
		pngWriteUInt32BE (ihdr + 4, (unsigned int)height);
		ihdr[8] = 8;  // bit depth
		ihdr[9] = 6;  // color type: truecolor + alpha
		ihdr[10] = 0; // compression
		ihdr[11] = 0; // filter
		ihdr[12] = 0; // interlace

		size_t total = 8 + 25 + (12 + (size_t)compressedLen) + 12;
		bytes->Resize ((int)total);

		unsigned char* out = bytes->b;
		static const unsigned char signature[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
		memcpy (out, signature, 8);

		size_t offset = 8;
		pngWriteChunk (out, &offset, "IHDR", ihdr, 13);
		pngWriteChunk (out, &offset, "IDAT", compressed, (size_t)compressedLen);
		pngWriteChunk (out, &offset, "IEND", NULL, 0);

		free (compressed);
		return true;

	}


	static bool EncodeSpng (ImageBuffer *imageBuffer, Bytes* bytes) {
		if (!imageBuffer || !bytes) return false;
		if (imageBuffer->bitsPerPixel != 32) return false;

		spng_ctx *ctx = spng_ctx_new (SPNG_CTX_ENCODER);
		if (!ctx) return false;

		int result = spng_set_option (ctx, SPNG_ENCODE_TO_BUFFER, 1);
		if (result != SPNG_OK) {
			spng_ctx_free (ctx);
			return false;
		}

		struct spng_ihdr ihdr = {};
		ihdr.width = imageBuffer->width;
		ihdr.height = imageBuffer->height;
		ihdr.bit_depth = 8;
		ihdr.color_type = SPNG_COLOR_TYPE_TRUECOLOR_ALPHA;
		ihdr.compression_method = 0;
		ihdr.filter_method = 0;
		ihdr.interlace_method = 0;

		result = spng_set_ihdr (ctx, &ihdr);
		if (result != SPNG_OK) {
			spng_ctx_free (ctx);
			return false;
		}

		size_t len = (size_t)imageBuffer->Stride () * (size_t)imageBuffer->height;
		unsigned char* imageData = imageBuffer->data->buffer->b;
		unsigned char* tempData = NULL;

		if (imageBuffer->format != RGBA32 || imageBuffer->premultiplied) {
			tempData = (unsigned char*)malloc (len);
			if (!tempData) {
				spng_ctx_free (ctx);
				return false;
			}

			const unsigned char* src = imageData;
			unsigned char* dest = tempData;
			const unsigned char* const end = src + len;

			while (src < end) {
				unsigned int r = 0, g = 0, b = 0, a = 0;

				switch (imageBuffer->format) {
					case BGRA32:
						b = src[0]; g = src[1]; r = src[2]; a = src[3];
						break;
					case ARGB32:
						a = src[0]; r = src[1]; g = src[2]; b = src[3];
						break;
					case RGBA32:
					default:
						r = src[0]; g = src[1]; b = src[2]; a = src[3];
						break;
				}

				if (imageBuffer->premultiplied && a != 0 && a != 255) {
					r = (r * 255 + (a / 2)) / a;
					g = (g * 255 + (a / 2)) / a;
					b = (b * 255 + (a / 2)) / a;
					if (r > 255) r = 255;
					if (g > 255) g = 255;
					if (b > 255) b = 255;
				}

				dest[0] = (unsigned char)r;
				dest[1] = (unsigned char)g;
				dest[2] = (unsigned char)b;
				dest[3] = (unsigned char)a;

				src += 4;
				dest += 4;
			}

			imageData = tempData;
		}

		result = spng_encode_image (ctx, imageData, len, SPNG_FMT_RGBA8, SPNG_ENCODE_FINALIZE);
		if (result != SPNG_OK) {
			if (tempData) free (tempData);
			spng_ctx_free (ctx);
			return false;
		}

		size_t pngSize = 0;
		int encodeError = SPNG_OK;
		void *pngData = spng_get_png_buffer (ctx, &pngSize, &encodeError);

		if (!pngData || encodeError != SPNG_OK) {
			spng_ctx_free (ctx);
			return false;
		}

		bytes->Resize ((int)pngSize);
		memcpy (bytes->b, pngData, pngSize);

		if (tempData) free (tempData);
		free (pngData);
		spng_ctx_free (ctx);

		return true;

	}


	bool PNG::Encode (ImageBuffer *imageBuffer, Bytes* bytes) {

		if (!imageBuffer || !bytes) return false;
		if (imageBuffer->bitsPerPixel != 32) return false;

		if (!imageBuffer->data || !imageBuffer->data->buffer || !imageBuffer->data->buffer->b) {

			fprintf (stderr, "[lime] PNG::Encode: the image buffer is empty\n");
			return false;

		}

		if (EncodeSpng (imageBuffer, bytes)) return true;

		fprintf (stderr, "[lime] PNG::Encode: spng failed, writing with the zlib fallback\n");
		return EncodeWithZlib (imageBuffer, bytes);

	}


}
