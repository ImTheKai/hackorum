module CommitImport
  # Discussion ids that are wrong in the commit message itself, not in how we
  # parse it: a dropped leading character, a double-encoded URL, an id cut off
  # before its domain. Nothing generic can repair these without guessing, so
  # they are listed one by one.
  #
  # Keys are the id as the parser hands it over - percent-decoded once, then
  # run through MessageIdNormalizer. Values are the id the archive really has.
  # Only add a pair after confirming exactly one archived message matches;
  # a wrong guess silently attaches a commit to someone else's thread.
  module MessageIdOverrides
    MAP = {
      # dropped leading character
      "9F503B5-32F2-45D7-A0AE-952879AD65F1@yesql.se" =>
        "F9F503B5-32F2-45D7-A0AE-952879AD65F1@yesql.se",
      "BB4C76F-D416-4F9F-949E-DBE950D37787@yesql.se" =>
        "BBB4C76F-D416-4F9F-949E-DBE950D37787@yesql.se",
      "AApHDvpN4v3t_sdz4dvrv1Fx_ZPw=twSnxuTEytRYP7LFz5K9A@mail.gmail.com" =>
        "CAApHDvpN4v3t_sdz4dvrv1Fx_ZPw=twSnxuTEytRYP7LFz5K9A@mail.gmail.com",
      "ec146256e31afa0542f9fa970ec258c5f1a5f98.camel@vmware.com" =>
        "4ec146256e31afa0542f9fa970ec258c5f1a5f98.camel@vmware.com",
      "fcd57e4-8f23-4c3e-a5db-2571d09208e2@beta.fastmail.com" =>
        "bfcd57e4-8f23-4c3e-a5db-2571d09208e2@beta.fastmail.com",

      # extra leading character
      "gY0y9xenfoBPc-Tufsr2Zg-MmkrJslm0Tw_CMg4p_j58-k_PXNC0klMdkKQkg61BkXC9_uWo-DcUzfxnHqpkpoR5jjVZrPHqKYikcHIiONhg=@yesql.se" =>
        "Y0y9xenfoBPc-Tufsr2Zg-MmkrJslm0Tw_CMg4p_j58-k_PXNC0klMdkKQkg61BkXC9_uWo-DcUzfxnHqpkpoR5jjVZrPHqKYikcHIiONhg=@yesql.se",

      # double-encoded url, so one decode still leaves %40 for the @
      "72a23702-6d96-4103-a54b-057c2352e885%40eisentraut.org" =>
        "72a23702-6d96-4103-a54b-057c2352e885@eisentraut.org",
      "DGPW5WCFY7WY.1IHCDNIVVT300%40jeltef.nl" =>
        "DGPW5WCFY7WY.1IHCDNIVVT300@jeltef.nl",

      # cut off before the domain
      "CAAJ_b97Hf+1SXnm8jySpO+Fhm+-VKFAAce1T_cupUYtnE3Nxig" =>
        "CAAJ_b97Hf+1SXnm8jySpO+Fhm+-VKFAAce1T_cupUYtnE3Nxig@mail.gmail.com",
      "1128176d-1eee-55d4-37ca-e63644422adb" =>
        "1128176d-1eee-55d4-37ca-e63644422adb@enterprisedb.com",
      "2729c9e2-9aac-8cda-f2f4-34f2bcc18f4e" =>
        "2729c9e2-9aac-8cda-f2f4-34f2bcc18f4e@enterprisedb.com",
      "20200515.090333.24867479329066911.horikyota.ntt" =>
        "20200515.090333.24867479329066911.horikyota.ntt@gmail.com"
    }.freeze

    def self.apply(id)
      MAP.fetch(id, id)
    end
  end
end
