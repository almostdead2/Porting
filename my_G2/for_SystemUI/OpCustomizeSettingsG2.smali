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
