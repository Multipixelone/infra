{
  flake.modules.nixos.pc = {
    services.printing.enable = true;

    hardware.printers = {
      ensurePrinters = [
        {
          name = "Brother_HL_L2460DW";
          description = "Brother HL-L2460DW";
          deviceUri = "ipp://192.168.3.131/ipp/print";
          model = "everywhere";
          ppdOptions = {
            PageSize = "Letter";
            Duplex = "DuplexNoTumble"; # two-sided-long-edge
          };
        }
      ];
      ensureDefaultPrinter = "Brother_HL_L2460DW";
    };
  };
}
