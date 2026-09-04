package main

import (
	"testing"
	"time"
)

func TestParseSyncPeriod(t *testing.T) {
	cases := []struct {
		in      string
		want    time.Duration
		wantErr bool
	}{
		{"", 36000 * time.Second, false},
		{"600", 600 * time.Second, false},
		{"0", 0, true},
		{"-5", 0, true},
		{"ten", 0, true},
	}
	for _, tc := range cases {
		got, err := parseSyncPeriod(tc.in)
		if (err != nil) != tc.wantErr || got != tc.want {
			t.Errorf("parseSyncPeriod(%q) = %v, %v; want %v, err=%v", tc.in, got, err, tc.want, tc.wantErr)
		}
	}
}

func TestParseAllowSystemNamespaces(t *testing.T) {
	cases := []struct {
		in      string
		want    bool
		wantErr bool
	}{
		{"", false, false},
		{"true", true, false},
		{"1", true, false},
		{"false", false, false},
		{"yes", false, true},
	}
	for _, tc := range cases {
		got, err := parseAllowSystemNamespaces(tc.in)
		if (err != nil) != tc.wantErr || got != tc.want {
			t.Errorf("parseAllowSystemNamespaces(%q) = %v, %v; want %v, err=%v", tc.in, got, err, tc.want, tc.wantErr)
		}
	}
}

func TestParseRenderPolicy(t *testing.T) {
	p, err := parseRenderPolicy("NAMESPACECONFIG", "", "", "")
	if err != nil || p.AllowedKinds != nil || p.RequireSelectedNamespace || p.DisableLookup {
		t.Errorf("empty env must be the zero policy, got %+v err=%v", p, err)
	}
	p, err = parseRenderPolicy("NAMESPACECONFIG", " Role, RoleBinding ,", "true", "1")
	if err != nil || len(p.AllowedKinds) != 2 || !p.AllowedKinds["Role"] || !p.AllowedKinds["RoleBinding"] || !p.RequireSelectedNamespace || !p.DisableLookup {
		t.Errorf("full policy not parsed, got %+v err=%v", p, err)
	}
	if _, err := parseRenderPolicy("GROUPCONFIG", "", "true", ""); err == nil {
		t.Error("REQUIRE_SELECTED_NAMESPACE must be rejected for GROUPCONFIG")
	}
	if _, err := parseRenderPolicy("NAMESPACECONFIG", " , ", "", ""); err == nil {
		t.Error("an ALLOWED_KINDS that names no kind must be rejected")
	}
	if _, err := parseRenderPolicy("NAMESPACECONFIG", "", "yes", ""); err == nil {
		t.Error("a non-boolean REQUIRE_SELECTED_NAMESPACE must be rejected")
	}
	if _, err := parseRenderPolicy("NAMESPACECONFIG", "", "", "maybe"); err == nil {
		t.Error("a non-boolean DISABLE_TEMPLATE_LOOKUP must be rejected")
	}
}
