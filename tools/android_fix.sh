sed -i -E 's/(com.android.application" version )"[0-9.]+"/\1"8.3.2"/' android/settings.gradle
sed -i -E 's/gradle-[0-9.]+-(all|bin)/gradle-8.6-all/' android/gradle/wrapper/gradle-wrapper.properties
grep -n "version" android/settings.gradle
cat android/gradle/wrapper/gradle-wrapper.properties
