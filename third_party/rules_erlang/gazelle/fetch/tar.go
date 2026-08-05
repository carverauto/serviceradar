package fetch

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

func ExtractTar(archive string, dest string) error {
	reader, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer reader.Close()
	return extractTar(reader, dest)
}

func ExtractTarGz(archive string, dest string) error {
	reader, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer reader.Close()

	uncompressedStream, err := gzip.NewReader(reader)
	if err != nil {
		return err
	}
	defer uncompressedStream.Close()
	return extractTar(uncompressedStream, dest)
}

func extractTar(reader io.Reader, dest string) error {
	tarReader := tar.NewReader(reader)
	var header *tar.Header
	var err error
	for header, err = tarReader.Next(); err == nil; header, err = tarReader.Next() {
		destPath := filepath.Join(dest, header.Name)
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(destPath, 0755); err != nil {
				return err
			}
		case tar.TypeReg:
			destDir := filepath.Dir(destPath)
			if err := os.MkdirAll(destDir, 0755); err != nil {
				return err
			}

			outFile, err := os.OpenFile(destPath, os.O_CREATE|os.O_RDWR, os.FileMode(header.Mode))
			if err != nil {
				return err
			}

			if _, err := io.Copy(outFile, tarReader); err != nil {
				outFile.Close()
				return err
			}
			if err := outFile.Close(); err != nil {
				return err
			}
		case tar.TypeSymlink:
			err := os.Symlink(header.Linkname, destPath)
			if err != nil {
				return err
			}
		case tar.TypeXGlobalHeader:
		default:
			return fmt.Errorf("extractTar: uknown type: %b in %s", header.Typeflag, header.Name)
		}
	}
	if err != io.EOF {
		return err
	}
	return nil
}
