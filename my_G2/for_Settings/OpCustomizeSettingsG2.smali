.class public Lcom/oneplus/custom/utils/OpCustomizeSettingsG2;
.super Lcom/oneplus/custom/utils/OpCustomizeSettings;
.source "OpCustomizeSettingsG2.java"


# direct methods
.method public constructor <init>()V
    .registers 1

    invoke-direct {p0}, Lcom/oneplus/custom/utils/OpCustomizeSettings;-><init>()V

    return-void
.end method


# virtual methods
.method protected getCustomization()Lcom/oneplus/custom/utils/OpCustomizeSettings$CUSTOM_TYPE;
    .registers 6

    .line 11
    sget-object v0, Lcom/oneplus/custom/utils/OpCustomizeSettings$CUSTOM_TYPE;->NONE:Lcom/oneplus/custom/utils/OpCustomizeSettings$CUSTOM_TYPE;

    .line 12
    .line 13
    .local v0, "custom_type":Lcom/oneplus/custom/utils/OpCustomizeSettings$CUSTOM_TYPE;
    const-string v2, "ro.boot.cust"

    invoke-static {v2}, Landroid/os/SystemProperties;->get(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v2

    .line 14
    .local v2, "bootprop":Ljava/lang/String;
    new-instance v3, Ljava/io/File;

    const-string v4, "/vendor/etc/janib"

    invoke-direct {v3, v4}, Ljava/io/File;-><init>(Ljava/lang/String;)V

    invoke-virtual {v3}, Ljava/io/File;->exists()Z

    move-result v3

    if-eqz v3, :cond_2c

    const-string v3, "8"

    invoke-virtual {v2, v3}, Ljava/lang/String;->contains(Ljava/lang/CharSequence;)Z

    move-result v3

    if-nez v3, :cond_26

    const-string v4, "6"

    invoke-virtual {v2, v4}, Ljava/lang/String;->contains(Ljava/lang/CharSequence;)Z

    move-result v4

    if-nez v4, :cond_29

    goto :goto_2c

    .line 31
    :cond_26
    sget-object v3, Lcom/oneplus/custom/utils/OpCustomizeSettings$CUSTOM_TYPE;->RED:Lcom/oneplus/custom/utils/OpCustomizeSettings$CUSTOM_TYPE;

    return-object v3

    :cond_29
    sget-object v3, Lcom/oneplus/custom/utils/OpCustomizeSettings$CUSTOM_TYPE;->MCL:Lcom/oneplus/custom/utils/OpCustomizeSettings$CUSTOM_TYPE;

    return-object v3

    .line 15
    .line 28
    :cond_2c
    :goto_2c
    return-object v0
.end method

.method protected getSoftwareType()Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;
    .registers 3

    .line 31
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->DEFAULT:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    .line 32
    invoke-static {}, Lcom/oneplus/custom/utils/ParamReader;->getSwTypeVal()I

    move-result v0

    if-eqz v0, :cond_33

    const/4 v1, 0x1

    if-eq v0, v1, :cond_30

    const/4 v1, 0x2

    if-eq v0, v1, :cond_2d

    const/4 v1, 0x3

    if-eq v0, v1, :cond_2a

    const/4 v1, 0x4

    if-eq v0, v1, :cond_27

    packed-switch v0, :pswitch_data_36

    goto :goto_35

    .line 63
    :pswitch_18  #0x69
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->C532:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    goto :goto_35

    .line 60
    :pswitch_1b  #0x68
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->ATT:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    goto :goto_35

    .line 57
    :pswitch_1e  #0x67
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->VERIZON:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    goto :goto_35

    .line 54
    :pswitch_21  #0x66
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->SPRINT:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    goto :goto_35

    .line 51
    :pswitch_24  #0x65
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->TMO:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    goto :goto_35

    .line 47
    :cond_27
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->EU:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    goto :goto_35

    .line 44
    :cond_2a
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->IN:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    goto :goto_35

    .line 41
    :cond_2d
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->H2:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    goto :goto_35

    .line 38
    :cond_30
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->O2:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    goto :goto_35

    .line 35
    :cond_33
    sget-object p0, Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;->DEFAULT:Lcom/oneplus/custom/utils/OpCustomizeSettings$SW_TYPE;

    :goto_35
    return-object p0

    :pswitch_data_36
    .packed-switch 0x65
        :pswitch_24  #00000065
        :pswitch_21  #00000066
        :pswitch_1e  #00000067
        :pswitch_1b  #00000068
        :pswitch_18  #00000069
    .end packed-switch
.end method
