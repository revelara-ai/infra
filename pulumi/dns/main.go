package main

import (
	"github.com/pulumi/pulumi-gcp/sdk/v8/go/gcp/dns"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "revelara-dns")
		domain := cfg.Require("domain")
		prodIP := cfg.Require("prodIP")
		devIP := cfg.Require("devIP")

		// ---------------------------------------------------------------
		// Public zone for revelara.ai
		// ---------------------------------------------------------------
		publicZone, err := dns.NewManagedZone(ctx, "revelara-ai-public", &dns.ManagedZoneArgs{
			Name:        pulumi.String("revelara-ai-public"),
			DnsName:     pulumi.Sprintf("%s.", domain),
			Description: pulumi.String("Public DNS zone for revelara.ai"),
			Visibility:  pulumi.String("public"),
			DnssecConfig: &dns.ManagedZoneDnssecConfigArgs{
				State: pulumi.String("on"),
			},
		})
		if err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// GitHub Pages: apex domain A records + www CNAME
		// ---------------------------------------------------------------
		_, err = dns.NewRecordSet(ctx, "apex", &dns.RecordSetArgs{
			Name:        pulumi.Sprintf("%s.", domain),
			ManagedZone: publicZone.Name,
			Type:        pulumi.String("A"),
			Ttl:         pulumi.Int(3600),
			Rrdatas: pulumi.StringArray{
				pulumi.String("185.199.108.153"),
				pulumi.String("185.199.109.153"),
				pulumi.String("185.199.110.153"),
				pulumi.String("185.199.111.153"),
			},
		})
		if err != nil {
			return err
		}

		_, err = dns.NewRecordSet(ctx, "www", &dns.RecordSetArgs{
			Name:        pulumi.Sprintf("www.%s.", domain),
			ManagedZone: publicZone.Name,
			Type:        pulumi.String("CNAME"),
			Ttl:         pulumi.Int(3600),
			Rrdatas: pulumi.StringArray{
				// GitHub org name will change to revelara after org rename
				pulumi.String("revelara.github.io."),
			},
		})
		if err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// Production A records -> 35.190.21.244
		// ---------------------------------------------------------------
		_, err = dns.NewRecordSet(ctx, "app-prod", &dns.RecordSetArgs{
			Name:        pulumi.Sprintf("app.%s.", domain),
			ManagedZone: publicZone.Name,
			Type:        pulumi.String("A"),
			Ttl:         pulumi.Int(300),
			Rrdatas:     pulumi.StringArray{pulumi.String(prodIP)},
		})
		if err != nil {
			return err
		}

		_, err = dns.NewRecordSet(ctx, "api-prod", &dns.RecordSetArgs{
			Name:        pulumi.Sprintf("api.%s.", domain),
			ManagedZone: publicZone.Name,
			Type:        pulumi.String("A"),
			Ttl:         pulumi.Int(300),
			Rrdatas:     pulumi.StringArray{pulumi.String(prodIP)},
		})
		if err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// Development A records -> 34.8.112.227
		// ---------------------------------------------------------------
		_, err = dns.NewRecordSet(ctx, "app-dev", &dns.RecordSetArgs{
			Name:        pulumi.Sprintf("dev.%s.", domain),
			ManagedZone: publicZone.Name,
			Type:        pulumi.String("A"),
			Ttl:         pulumi.Int(300),
			Rrdatas:     pulumi.StringArray{pulumi.String(devIP)},
		})
		if err != nil {
			return err
		}

		_, err = dns.NewRecordSet(ctx, "api-dev", &dns.RecordSetArgs{
			Name:        pulumi.Sprintf("api-dev.%s.", domain),
			ManagedZone: publicZone.Name,
			Type:        pulumi.String("A"),
			Ttl:         pulumi.Int(300),
			Rrdatas:     pulumi.StringArray{pulumi.String(devIP)},
		})
		if err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// Google Workspace MX (single RecordSet, all priorities)
		// ---------------------------------------------------------------
		_, err = dns.NewRecordSet(ctx, "mx", &dns.RecordSetArgs{
			Name:        pulumi.Sprintf("%s.", domain),
			ManagedZone: publicZone.Name,
			Type:        pulumi.String("MX"),
			Ttl:         pulumi.Int(3600),
			Rrdatas: pulumi.StringArray{
				pulumi.String("1 smtp.google.com."),
			},
		})
		if err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// Root TXT records (SPF + Google site verification)
		// Cloud DNS requires one RecordSet per name+type, so all TXT
		// records for the apex go in a single resource.
		// ---------------------------------------------------------------
		_, err = dns.NewRecordSet(ctx, "root-txt", &dns.RecordSetArgs{
			Name:        pulumi.Sprintf("%s.", domain),
			ManagedZone: publicZone.Name,
			Type:        pulumi.String("TXT"),
			Ttl:         pulumi.Int(3600),
			Rrdatas: pulumi.StringArray{
				// SPF: allow Google Workspace and SendGrid
				pulumi.String("\"v=spf1 include:_spf.google.com include:sendgrid.net ~all\""),
				// Google Workspace domain verification
				pulumi.String("\"google-site-verification=1j2eEVjEaYeyBQv9PiWZ4mM-2Zak1X0g6y-V-CcyHUc\""),
			},
		})
		if err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// DMARC policy
		// ---------------------------------------------------------------
		_, err = dns.NewRecordSet(ctx, "dmarc", &dns.RecordSetArgs{
			Name:        pulumi.Sprintf("_dmarc.%s.", domain),
			ManagedZone: publicZone.Name,
			Type:        pulumi.String("TXT"),
			Ttl:         pulumi.Int(3600),
			Rrdatas: pulumi.StringArray{
				pulumi.Sprintf("\"v=DMARC1; p=quarantine; rua=mailto:dmarc@%s; pct=100\"", domain),
			},
		})
		if err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// Outputs: nameservers to configure at Squarespace registrar
		// ---------------------------------------------------------------
		ctx.Export("zoneNameServers", publicZone.NameServers)
		ctx.Export("zoneName", publicZone.Name)

		return nil
	})
}
