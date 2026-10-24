# From a photo to a video

*Deutsch: [de/FOTO_ZU_VIDEO.md](de/FOTO_ZU_VIDEO.md)*

Take a photo of a person, describe a role, and NVAI-open puts the person into that role and makes a
video in which they move and speak. In this example a casual portrait becomes a king who says
"Everyone can be a king these days." Then the camera zooms out to the film set: the throne room is a
painted backdrop, and under the velvet cloak he wears jogging pants and sneakers.

![The photo, the start image and three frames of the video](images/photo-video-chain.jpg)

<p align="center"><img src="images/photo-video-king.gif" width="420" alt="The king says his line, then the camera zooms out to the film set"></p>
<p align="center"><sub>The video as a GIF, without sound. <a href="videos/photo-video-king.mp4">MP4 with sound</a> (3 MB).</sub></p>

The photo in this example was generated with NVAI-open as well: this man does not exist. Use only
photos of people who agreed to it.

## What you need

| | |
|---|---|
| FLUX 3 Image Klein | makes the start images from the photo; 20.2 GB download (NVFP4 for RTX 50, INT8 with 17.8 GB for RTX 20/30/40) |
| LTX-2.5 | turns the start image into a video with sound; 37.5 GB download |
| Time | measured on an RTX 5060 Ti with 16 GB: four start images in 96 s, the 7-second video in 144 s |

Both are under "Models". Their repositories on Hugging Face are gated: accept the license there
first and store your token in NVAI-open.

## Step 1: pick the photo

In the "Video" tab, upload the photo with "Upload image" or click it in the list. A photo that shows
only head and shoulders works best, because FLUX 3 takes the face from it.

![Start image: the photo is selected](images/photo-video-1.jpg)

## Step 2: describe the role

Open "Person from a photo" and write who the person should be: clothing, place, style, in English
or German. Then click "Create four start images".

![Person from a photo: the role is described](images/photo-video-2.jpg)

Name clothing and surroundings explicitly. Whatever you leave open, FLUX 3 invents.

## Step 3: pick the most similar start image

About a minute and a half later four start images in the video format are at the front of the list,
and the first one is selected. Click the one that looks most like the person, and look at them at
full resolution: FLUX 3 tends to make faces a little slimmer and younger.

![Four start images, the chosen one is marked](images/photo-video-3.jpg)

## Step 4: describe what happens

In the prompt, write in one paragraph what moves, what the camera does, the spoken line in quotation
marks together with the voice, and the sounds. Set the length (7 s here) and click "Generate".

![Prompt with the spoken line and the zoom out; size and length](images/photo-video-4.jpg)

## Tips from our tests

- **Keep the person facing the camera.** If they turn away, LTX-2.5 redraws the face afterwards and it
  looks less like the photo.
- **Say exactly what the camera does.** "The camera holds a steady medium shot" keeps the framing;
  "pulls back a little" turned into a wide shot in our test. For a reveal like the one above, write
  "zooms out and reveals …".
- **Describe the voice and how loud things are**, for example "says in a deep, calm voice". Sounds
  described as quiet come out very quiet.
- **The voice is generated.** It is never the person's real voice.
- **Licenses:** FLUX 3 images may be used commercially only below US$5 million annual revenue, and
  every image has to be reviewed before it is published (FLUX Kommunity License). LTX-2.5 is free
  below US$10 million revenue (LTX-2 Community License).

## Over MCP (Claude Code)

The same in two calls: `generate_image` with `flux3-klein-nvfp4`, the photo in `reference_asset_ids`,
`batch_size=4`, the video size (`width=1280, height=704`) and the prompt "Cinematic film still. The
person from the first image, with exactly the same face, eyes, nose, mouth and hair color: <role>.
Medium shot from the waist up, the face clearly visible." Then `generate_video` with the chosen image
as `image_asset_id`. More in [CLAUDE_CODE.md](CLAUDE_CODE.md#person-from-a-photo-since-058).
