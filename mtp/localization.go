package main

import "os"

var language = os.Getenv("ANDROID_FINDER_LANGUAGE")

func localized(english, french, spanish string) string {
	switch language {
	case "fr":
		return french
	case "es":
		return spanish
	default:
		return english
	}
}
