module VERIFICATION
  imports PATH

endmodule

module ALL-PATH-B-D-SPEC
  imports VERIFICATION
  imports PATH

  // This should be provable
  rule <k> b => d </k> [all-path]

endmodule
